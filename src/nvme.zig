const std = @import("std");
const pci = @import("pci.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");

const cc = std.os.uefi.cc;

const pci_command_memory_space: u16 = 1 << 1;
const pci_command_bus_master: u16 = 1 << 2;

const cap_offset: usize = 0x00;
const version_offset: usize = 0x08;
const interrupt_mask_set_offset: usize = 0x0C;
const controller_configuration_offset: usize = 0x14;
const controller_status_offset: usize = 0x1C;
const admin_queue_attributes_offset: usize = 0x24;
const admin_submission_queue_offset: usize = 0x28;
const admin_completion_queue_offset: usize = 0x30;
const doorbell_base_offset: usize = 0x1000;

const controller_enable: u32 = 1 << 0;
const controller_ready: u32 = 1 << 0;
const controller_fatal_status: u32 = 1 << 1;
const io_submission_entry_size: u32 = 6 << 16;
const io_completion_entry_size: u32 = 4 << 20;

const admin_delete_io_submission_queue: u8 = 0x00;
const admin_create_io_submission_queue: u8 = 0x01;
const admin_delete_io_completion_queue: u8 = 0x04;
const admin_create_io_completion_queue: u8 = 0x05;
const admin_identify: u8 = 0x06;
const nvm_read: u8 = 0x02;

const identify_namespace: u32 = 0x00;
const identify_controller: u32 = 0x01;
const identify_active_namespace_list: u32 = 0x02;

const maximum_poll_iterations: usize = 100_000_000;
const requested_queue_depth: u16 = 16;
const mmio_probe_size: u64 = 16 * 1024;

pub const FailureStage = enum(u8) {
    none,
    pci_command,
    bar,
    mapping,
    capabilities,
    disable,
    allocation,
    enable,
    identify_controller,
    namespace_list,
    identify_namespace,
    create_io_queues,
    io_read,
};

pub var last_failure_stage: FailureStage = .none;
pub var last_completion_status: u16 = 0;
pub var last_completion_command_id: u16 = 0;
pub var last_completion_queue_id: u16 = 0;
pub var last_controller_status: u32 = 0;
pub var last_controller_configuration: u32 = 0;
pub var last_command_opcode: u8 = 0;
pub var last_bar: u64 = 0;
pub var last_mapping_present: bool = false;

const Submission = extern struct {
    opcode: u8,
    flags: u8,
    command_id: u16,
    namespace_id: u32,
    reserved2: u64,
    metadata_pointer: u64,
    prp1: u64,
    prp2: u64,
    command_dword10: u32,
    command_dword11: u32,
    command_dword12: u32,
    command_dword13: u32,
    command_dword14: u32,
    command_dword15: u32,
};

const Completion = extern struct {
    result: u32,
    reserved: u32,
    submission_head: u16,
    submission_queue_id: u16,
    command_id: u16,
    status: u16,
};

const CompletionRecord = struct {
    result: u32,
    submission_head: u16,
    submission_queue_id: u16,
    command_id: u16,
    status: u16,
};

pub const Queue = struct {
    submission_address: usize,
    completion_address: usize,
    depth: u16,
    queue_id: u16,
    submission_tail: u16,
    completion_head: u16,
    completion_phase: u1,
};

pub const Controller = struct {
    pci_function: pci.Function,
    bar: usize,
    pci_command: u16,
    capabilities: u64,
    version: u32,
    maximum_queue_entries: u32,
    doorbell_stride: usize,
    timeout_units: u8,
    mapped_base: u64,
    mapped_bytes: u64,
    mapping_table_pages: u64,
    admin_queue: Queue,
    io_queue: Queue,
    next_command_id: u16,
    serial_number: [21]u8,
    model_number: [41]u8,
    firmware_revision: [9]u8,
    namespace_count: u32,
    namespace_id: u32,
    namespace_size_lbas: u64,
    namespace_capacity_lbas: u64,
    logical_block_size: u32,
    metadata_size: u16,
    capacity_bytes: u64,
    identify_controller_address: usize,
    namespace_list_address: usize,
    identify_namespace_address: usize,
};

pub const ReadResult = struct {
    namespace_id: u32,
    lba: u64,
    byte_count: u32,
    buffer_address: usize,
    first_bytes: [16]u8,
    mbr_signature: u16,
    fnv1a64: u64,
};

extern fn zigos_memory_fence() callconv(cc) void;

pub fn initialize(function: pci.Function, allocator: *memory.FrameAllocator) ?Controller {
    last_failure_stage = .pci_command;
    last_completion_status = 0;
    last_completion_command_id = 0;
    last_completion_queue_id = 0;
    last_controller_status = 0;
    last_controller_configuration = 0;
    last_command_opcode = 0;
    last_bar = 0;
    last_mapping_present = false;
    if (function.class_code != 0x01 or function.subclass != 0x08 or function.programming_interface != 0x02) {
        return null;
    }

    var command = pci.readConfiguration16(function, 0x04);
    const required_command = pci_command_memory_space | pci_command_bus_master;
    if ((command & required_command) != required_command) {
        command |= required_command;
        pci.writeConfiguration16(function, 0x04, command);
        command = pci.readConfiguration16(function, 0x04);
        if ((command & required_command) != required_command) return null;
    }

    last_failure_stage = .bar;
    const bar = decodeBar(function) orelse return null;
    last_bar = @intCast(bar);
    last_failure_stage = .mapping;
    var mapped_base: u64 = @intCast(bar);
    var mapped_bytes: u64 = mmio_probe_size;
    var mapping_table_pages: u64 = 0;
    if (@as(u64, @intCast(bar)) >= memory.four_gib) {
        last_mapping_present = paging.isIdentityRangeMapped(@intCast(bar), mmio_probe_size);
        if (last_mapping_present) {
            mapped_base = @as(u64, @intCast(bar)) & ~(@as(u64, 2 * 1024 * 1024 - 1));
            mapped_bytes = 2 * 1024 * 1024;
        } else {
            const mapping = paging.mapIdentityMmio(allocator, @intCast(bar), mmio_probe_size) orelse return null;
            mapped_base = mapping.mapped_base;
            mapped_bytes = mapping.mapped_bytes;
            mapping_table_pages = mapping.table_pages;
        }
    }

    last_failure_stage = .capabilities;
    const capabilities = read64(bar, cap_offset);
    const maximum_queue_entries: u32 = @intCast((capabilities & 0xFFFF) + 1);
    if (maximum_queue_entries < 2) return null;
    const supports_nvm_command_set = ((capabilities >> 37) & 1) != 0;
    if (!supports_nvm_command_set) return null;
    const minimum_page_shift: u6 = @intCast(12 + ((capabilities >> 48) & 0xF));
    const maximum_page_shift: u6 = @intCast(12 + ((capabilities >> 52) & 0xF));
    if (minimum_page_shift > 12 or maximum_page_shift < 12) return null;

    const doorbell_shift: u6 = @intCast(2 + ((capabilities >> 32) & 0xF));
    const doorbell_stride = @as(usize, 1) << doorbell_shift;
    const final_doorbell_offset = doorbell_base_offset + 3 * doorbell_stride + @sizeOf(u32);
    if (final_doorbell_offset > mapped_bytes) return null;

    last_failure_stage = .disable;
    if (!disableController(bar)) return null;

    last_failure_stage = .allocation;
    const queue_depth: u16 = @intCast(@min(maximum_queue_entries, @as(u32, requested_queue_depth)));
    const admin_submission_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const admin_completion_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    zeroPage(admin_submission_address);
    zeroPage(admin_completion_address);

    write32(bar, interrupt_mask_set_offset, 0xFFFF_FFFF);
    write32(
        bar,
        admin_queue_attributes_offset,
        (@as(u32, queue_depth - 1) << 16) | @as(u32, queue_depth - 1),
    );
    write64(bar, admin_submission_queue_offset, admin_submission_address);
    write64(bar, admin_completion_queue_offset, admin_completion_address);
    last_failure_stage = .enable;
    write32(
        bar,
        controller_configuration_offset,
        controller_enable | io_submission_entry_size | io_completion_entry_size,
    );
    if (!waitForReady(bar, true)) return null;

    const io_submission_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const io_completion_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    zeroPage(io_submission_address);
    zeroPage(io_completion_address);

    var controller = Controller{
        .pci_function = function,
        .bar = bar,
        .pci_command = command,
        .capabilities = capabilities,
        .version = read32(bar, version_offset),
        .maximum_queue_entries = maximum_queue_entries,
        .doorbell_stride = doorbell_stride,
        .timeout_units = @truncate(capabilities >> 24),
        .mapped_base = mapped_base,
        .mapped_bytes = mapped_bytes,
        .mapping_table_pages = mapping_table_pages,
        .admin_queue = .{
            .submission_address = admin_submission_address,
            .completion_address = admin_completion_address,
            .depth = queue_depth,
            .queue_id = 0,
            .submission_tail = 0,
            .completion_head = 0,
            .completion_phase = 1,
        },
        .io_queue = .{
            .submission_address = io_submission_address,
            .completion_address = io_completion_address,
            .depth = queue_depth,
            .queue_id = 1,
            .submission_tail = 0,
            .completion_head = 0,
            .completion_phase = 1,
        },
        .next_command_id = 1,
        .serial_number = undefined,
        .model_number = undefined,
        .firmware_revision = undefined,
        .namespace_count = 0,
        .namespace_id = 0,
        .namespace_size_lbas = 0,
        .namespace_capacity_lbas = 0,
        .logical_block_size = 0,
        .metadata_size = 0,
        .capacity_bytes = 0,
        .identify_controller_address = allocator.allocateBelow(memory.four_gib) orelse return null,
        .namespace_list_address = allocator.allocateBelow(memory.four_gib) orelse return null,
        .identify_namespace_address = allocator.allocateBelow(memory.four_gib) orelse return null,
    };
    zeroPage(controller.identify_controller_address);
    zeroPage(controller.namespace_list_address);
    zeroPage(controller.identify_namespace_address);

    last_failure_stage = .identify_controller;
    if (!identifyController(&controller)) return null;
    last_failure_stage = .namespace_list;
    if (!identifyActiveNamespace(&controller)) return null;
    last_failure_stage = .identify_namespace;
    if (!identifyNamespace(&controller)) return null;
    last_failure_stage = .create_io_queues;
    if (!createIoQueues(&controller)) return null;
    last_failure_stage = .none;
    return controller;
}

pub fn readOneBlock(controller: *Controller, allocator: *memory.FrameAllocator, lba: u64) ?ReadResult {
    last_failure_stage = .io_read;
    if (controller.logical_block_size < 512 or controller.logical_block_size > memory.page_size) return null;
    if (lba >= controller.namespace_size_lbas) return null;

    const buffer_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    zeroPage(buffer_address);
    var command = emptySubmission(nvm_read, controller.namespace_id);
    command.prp1 = buffer_address;
    command.command_dword10 = @truncate(lba);
    command.command_dword11 = @truncate(lba >> 32);
    command.command_dword12 = 0;
    _ = submit(
        controller.bar,
        controller.doorbell_stride,
        &controller.next_command_id,
        &controller.io_queue,
        command,
    ) orelse return null;
    zigos_memory_fence();

    const byte_count = controller.logical_block_size;
    const bytes: [*]volatile u8 = @ptrFromInt(buffer_address);
    var result = ReadResult{
        .namespace_id = controller.namespace_id,
        .lba = lba,
        .byte_count = byte_count,
        .buffer_address = buffer_address,
        .first_bytes = undefined,
        .mbr_signature = 0,
        .fnv1a64 = 0xCBF2_9CE4_8422_2325,
    };
    for (0..result.first_bytes.len) |index| result.first_bytes[index] = bytes[index];
    var index: usize = 0;
    while (index < byte_count) : (index += 1) {
        result.fnv1a64 ^= bytes[index];
        result.fnv1a64 *%= 0x0000_0100_0000_01B3;
    }
    result.mbr_signature = @as(u16, bytes[510]) |
        (@as(u16, bytes[511]) << 8);
    last_failure_stage = .none;
    return result;
}

pub fn readBuffer(result: ReadResult) []const u8 {
    const bytes: [*]const u8 = @ptrFromInt(result.buffer_address);
    return bytes[0..result.byte_count];
}

pub fn terminatedSlice(buffer: []const u8) []const u8 {
    var length = buffer.len;
    for (buffer, 0..) |character, index| {
        if (character == 0) {
            length = index;
            break;
        }
    }
    return buffer[0..length];
}

fn decodeBar(function: pci.Function) ?usize {
    const low = pci.readConfiguration32(function, 0x10);
    if ((low & 1) != 0) return null;
    const memory_type = (low >> 1) & 0x3;
    const base = switch (memory_type) {
        0 => @as(u64, low & 0xFFFF_FFF0),
        2 => @as(u64, low & 0xFFFF_FFF0) |
            (@as(u64, pci.readConfiguration32(function, 0x14)) << 32),
        else => return null,
    };
    if (base == 0 or base > std.math.maxInt(usize)) return null;
    return @intCast(base);
}

fn identifyController(controller: *Controller) bool {
    var command = emptySubmission(admin_identify, 0);
    command.prp1 = controller.identify_controller_address;
    command.command_dword10 = identify_controller;
    _ = submit(
        controller.bar,
        controller.doorbell_stride,
        &controller.next_command_id,
        &controller.admin_queue,
        command,
    ) orelse return false;
    zigos_memory_fence();

    const bytes: [*]volatile u8 = @ptrFromInt(controller.identify_controller_address);
    copyTrimmedAscii(bytes, 4, 20, &controller.serial_number);
    copyTrimmedAscii(bytes, 24, 40, &controller.model_number);
    copyTrimmedAscii(bytes, 64, 8, &controller.firmware_revision);
    controller.namespace_count = readBuffer32(bytes, 516);
    return controller.namespace_count != 0 and
        controller.serial_number[0] != 0 and controller.model_number[0] != 0;
}

fn identifyActiveNamespace(controller: *Controller) bool {
    var command = emptySubmission(admin_identify, 0);
    command.prp1 = controller.namespace_list_address;
    command.command_dword10 = identify_active_namespace_list;
    _ = submit(
        controller.bar,
        controller.doorbell_stride,
        &controller.next_command_id,
        &controller.admin_queue,
        command,
    ) orelse return false;
    zigos_memory_fence();

    const bytes: [*]volatile u8 = @ptrFromInt(controller.namespace_list_address);
    controller.namespace_id = readBuffer32(bytes, 0);
    return controller.namespace_id != 0;
}

fn identifyNamespace(controller: *Controller) bool {
    var command = emptySubmission(admin_identify, controller.namespace_id);
    command.prp1 = controller.identify_namespace_address;
    command.command_dword10 = identify_namespace;
    _ = submit(
        controller.bar,
        controller.doorbell_stride,
        &controller.next_command_id,
        &controller.admin_queue,
        command,
    ) orelse return false;
    zigos_memory_fence();

    const bytes: [*]volatile u8 = @ptrFromInt(controller.identify_namespace_address);
    controller.namespace_size_lbas = readBuffer64(bytes, 0);
    controller.namespace_capacity_lbas = readBuffer64(bytes, 8);
    const formatted_lba_index: usize = bytes[26] & 0x0F;
    if (formatted_lba_index >= 16) return false;
    const format_offset = 128 + formatted_lba_index * 4;
    const format = readBuffer32(bytes, format_offset);
    controller.metadata_size = @truncate(format);
    const block_shift: u8 = @truncate(format >> 16);
    if (block_shift < 9 or block_shift >= 32) return false;
    controller.logical_block_size = @as(u32, 1) << @as(u5, @intCast(block_shift));
    if (controller.metadata_size != 0) return false;
    if (controller.namespace_size_lbas == 0 or controller.namespace_capacity_lbas == 0) return false;
    controller.capacity_bytes = controller.namespace_capacity_lbas *| @as(u64, controller.logical_block_size);
    return controller.logical_block_size <= memory.page_size;
}

fn createIoQueues(controller: *Controller) bool {
    var completion_command = emptySubmission(admin_create_io_completion_queue, 0);
    completion_command.prp1 = controller.io_queue.completion_address;
    completion_command.command_dword10 = @as(u32, controller.io_queue.queue_id) |
        (@as(u32, controller.io_queue.depth - 1) << 16);
    completion_command.command_dword11 = 1;
    _ = submit(
        controller.bar,
        controller.doorbell_stride,
        &controller.next_command_id,
        &controller.admin_queue,
        completion_command,
    ) orelse return false;

    var submission_command = emptySubmission(admin_create_io_submission_queue, 0);
    submission_command.prp1 = controller.io_queue.submission_address;
    submission_command.command_dword10 = @as(u32, controller.io_queue.queue_id) |
        (@as(u32, controller.io_queue.depth - 1) << 16);
    submission_command.command_dword11 = 1 | (@as(u32, controller.io_queue.queue_id) << 16);
    _ = submit(
        controller.bar,
        controller.doorbell_stride,
        &controller.next_command_id,
        &controller.admin_queue,
        submission_command,
    ) orelse {
        var cleanup = emptySubmission(admin_delete_io_completion_queue, 0);
        cleanup.command_dword10 = controller.io_queue.queue_id;
        _ = submit(
            controller.bar,
            controller.doorbell_stride,
            &controller.next_command_id,
            &controller.admin_queue,
            cleanup,
        );
        return false;
    };
    return true;
}

fn submit(
    bar: usize,
    doorbell_stride: usize,
    next_command_id: *u16,
    queue: *Queue,
    initial_command: Submission,
) ?CompletionRecord {
    var command = initial_command;
    last_command_opcode = command.opcode;
    const command_id = next_command_id.*;
    next_command_id.* +%= 1;
    if (next_command_id.* == 0) next_command_id.* = 1;
    command.command_id = command_id;

    const submission_index: usize = queue.submission_tail;
    const submission: *volatile Submission = @ptrFromInt(
        queue.submission_address + submission_index * @sizeOf(Submission),
    );
    submission.* = command;
    zigos_memory_fence();

    queue.submission_tail += 1;
    if (queue.submission_tail == queue.depth) queue.submission_tail = 0;
    write32(
        bar,
        doorbell_base_offset + @as(usize, 2 * queue.queue_id) * doorbell_stride,
        queue.submission_tail,
    );

    var iteration: usize = 0;
    while (iteration < maximum_poll_iterations) : (iteration += 1) {
        const completion: *volatile Completion = @ptrFromInt(
            queue.completion_address + @as(usize, queue.completion_head) * @sizeOf(Completion),
        );
        const status = completion.status;
        last_completion_status = status;
        if ((status & 1) != queue.completion_phase) continue;
        zigos_memory_fence();
        const record = CompletionRecord{
            .result = completion.result,
            .submission_head = completion.submission_head,
            .submission_queue_id = completion.submission_queue_id,
            .command_id = completion.command_id,
            .status = status,
        };
        last_completion_command_id = record.command_id;
        last_completion_queue_id = record.submission_queue_id;
        if (record.command_id != command_id or record.submission_queue_id != queue.queue_id) return null;
        if ((record.status & 0xFFFE) != 0) return null;

        queue.completion_head += 1;
        if (queue.completion_head == queue.depth) {
            queue.completion_head = 0;
            queue.completion_phase ^= 1;
        }
        write32(
            bar,
            doorbell_base_offset + @as(usize, 2 * queue.queue_id + 1) * doorbell_stride,
            queue.completion_head,
        );
        return record;
    }
    return null;
}

fn emptySubmission(opcode: u8, namespace_id: u32) Submission {
    return .{
        .opcode = opcode,
        .flags = 0,
        .command_id = 0,
        .namespace_id = namespace_id,
        .reserved2 = 0,
        .metadata_pointer = 0,
        .prp1 = 0,
        .prp2 = 0,
        .command_dword10 = 0,
        .command_dword11 = 0,
        .command_dword12 = 0,
        .command_dword13 = 0,
        .command_dword14 = 0,
        .command_dword15 = 0,
    };
}

fn disableController(bar: usize) bool {
    const configuration = read32(bar, controller_configuration_offset);
    if ((configuration & controller_enable) != 0) {
        write32(bar, controller_configuration_offset, configuration & ~controller_enable);
    }
    return waitForReady(bar, false);
}

fn waitForReady(bar: usize, expected_ready: bool) bool {
    var iteration: usize = 0;
    while (iteration < maximum_poll_iterations) : (iteration += 1) {
        const status = read32(bar, controller_status_offset);
        last_controller_status = status;
        last_controller_configuration = read32(bar, controller_configuration_offset);
        if ((status & controller_fatal_status) != 0) return false;
        const ready = (status & controller_ready) != 0;
        if (ready == expected_ready) return true;
    }
    return false;
}

fn copyTrimmedAscii(source: [*]volatile u8, offset: usize, length: usize, destination: []u8) void {
    if (destination.len < length + 1) return;
    var effective_length = length;
    while (effective_length != 0) {
        const character = source[offset + effective_length - 1];
        if (character != 0 and character != ' ') break;
        effective_length -= 1;
    }
    var index: usize = 0;
    while (index < effective_length) : (index += 1) destination[index] = source[offset + index];
    destination[effective_length] = 0;
    index = effective_length + 1;
    while (index < destination.len) : (index += 1) destination[index] = 0;
}

fn readBuffer32(bytes: [*]volatile u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readBuffer64(bytes: [*]volatile u8, offset: usize) u64 {
    return @as(u64, readBuffer32(bytes, offset)) |
        (@as(u64, readBuffer32(bytes, offset + 4)) << 32);
}

fn zeroPage(address: usize) void {
    const bytes: [*]volatile u8 = @ptrFromInt(address);
    var index: usize = 0;
    while (index < memory.page_size) : (index += 1) bytes[index] = 0;
}

fn read32(base: usize, offset: usize) u32 {
    const register: *volatile u32 = @ptrFromInt(base + offset);
    return register.*;
}

fn read64(base: usize, offset: usize) u64 {
    const register: *volatile u64 = @ptrFromInt(base + offset);
    return register.*;
}

fn write32(base: usize, offset: usize, value: anytype) void {
    const register: *volatile u32 = @ptrFromInt(base + offset);
    register.* = @intCast(value);
}

fn write64(base: usize, offset: usize, value: anytype) void {
    const register: *volatile u64 = @ptrFromInt(base + offset);
    register.* = @intCast(value);
}

comptime {
    if (@sizeOf(Submission) != 64) @compileError("NVMe submission entries must be 64 bytes");
    if (@sizeOf(Completion) != 16) @compileError("NVMe completion entries must be 16 bytes");
}
