const std = @import("std");
const boot = @import("boot_info.zig");
const kernel = @import("kernel.zig");
const uefi = std.os.uefi;

const MemoryDescriptor = uefi.tables.MemoryDescriptor;
const MemoryMapSlice = uefi.tables.MemoryMapSlice;
const ConfigurationTable = uefi.tables.ConfigurationTable;
const GraphicsOutput = uefi.protocol.GraphicsOutput;

extern fn zigos_cpuid_vendor(out: [*]u8) callconv(uefi.cc) void;
extern fn zigos_read_cr0() callconv(uefi.cc) u64;
extern fn zigos_read_cr3() callconv(uefi.cc) u64;
extern fn zigos_read_cr4() callconv(uefi.cc) u64;
extern fn zigos_debug_putc(character: u8) callconv(uefi.cc) void;
extern fn zigos_halt_forever() callconv(uefi.cc) noreturn;
const KernelEntry = *const fn (*const boot.BootInfo) callconv(uefi.cc) noreturn;
extern fn zigos_enter_kernel(stack_top: [*]u8, info: *const boot.BootInfo, entry: KernelEntry) callconv(uefi.cc) noreturn;

var memory_map_storage: [256 * 1024]u8 align(@alignOf(MemoryDescriptor)) = undefined;
var boot_info: boot.BootInfo = undefined;

const MemorySummary = struct {
    total_pages: u64,
    conventional_pages: u64,
    highest_physical_address: u64,
};

pub fn main() noreturn {
    const system_table = uefi.system_table;
    const console = system_table.con_out orelse fatal(null, "UEFI console output is unavailable.");
    const boot_services = system_table.boot_services orelse fatal(console, "UEFI boot services are unavailable.");

    const kernel_stack_pages = boot_services.allocatePages(.any, .loader_data, 16) catch
        fatal(console, "Unable to allocate the 64 KiB ZigOs kernel stack.");
    boot_info.kernel_stack = .{
        .base = @intFromPtr(kernel_stack_pages.ptr),
        .size = kernel_stack_pages.len * @sizeOf(uefi.Page),
    };

    const trampoline_limit: [*]align(4096) uefi.Page = @ptrFromInt(0x000F_F000);
    const trampoline_pages = boot_services.allocatePages(
        .{ .max_address = trampoline_limit },
        .loader_data,
        1,
    ) catch fatal(console, "Unable to reserve an AP startup trampoline below 1 MiB.");
    boot_info.ap_trampoline = .{
        .base = @intFromPtr(trampoline_pages.ptr),
        .size = trampoline_pages.len * @sizeOf(uefi.Page),
    };
    if (boot_info.ap_trampoline.base >= 0x0010_0000 or
        (boot_info.ap_trampoline.base & 0xFFF) != 0 or
        boot_info.ap_trampoline.size != 4096)
    {
        fatal(console, "UEFI returned an invalid AP trampoline region.");
    }

    console.clearScreen() catch {};
    writeAscii(console, "ZigOs\r\n");
    writeAscii(console, "Experimental x86-64 operating system in Zig + Assembly\r\n\r\n");

    var vendor: [13]u8 = @splat(0);
    zigos_cpuid_vendor(&vendor);
    writeAscii(console, "CPU vendor: ");
    writeAscii(console, vendor[0..12]);
    writeAscii(console, "\r\n");

    writeRegister(console, "CR0", zigos_read_cr0());
    writeRegister(console, "CR3", zigos_read_cr3());
    writeRegister(console, "CR4", zigos_read_cr4());

    boot_info.acpi_rsdp = findAcpiRsdp(system_table);
    boot_info.framebuffer = findFramebuffer(boot_services);

    writeAscii(console, "\r\nFirmware discovery:\r\n");
    writeAscii(console, "  Kernel stack: 0x");
    writeHex64(console, @intCast(boot_info.kernel_stack.base));
    writeAscii(console, " + ");
    writeUsizeDecimal(console, boot_info.kernel_stack.size);
    writeAscii(console, " bytes\r\n");
    writeAscii(console, "  AP trampoline reservation: 0x");
    writeHex64(console, @intCast(boot_info.ap_trampoline.base));
    writeAscii(console, " + ");
    writeUsizeDecimal(console, boot_info.ap_trampoline.size);
    writeAscii(console, " bytes\r\n");
    if (boot_info.acpi_rsdp) |address| {
        writeAscii(console, "  ACPI RSDP: 0x");
        writeHex64(console, @intCast(address));
        writeAscii(console, "\r\n");
    } else {
        writeAscii(console, "  ACPI RSDP: not found\r\n");
    }

    if (boot_info.framebuffer) |framebuffer| {
        writeAscii(console, "  GOP framebuffer: ");
        writeU64Decimal(console, framebuffer.width);
        writeAscii(console, "x");
        writeU64Decimal(console, framebuffer.height);
        writeAscii(console, " at 0x");
        writeHex64(console, @intCast(framebuffer.base));
        writeAscii(console, "\r\n");
    } else {
        writeAscii(console, "  GOP framebuffer: unavailable or BLT-only\r\n");
    }

    const preliminary_map = boot_services.getMemoryMap(memory_map_storage[0..]) catch
        fatal(console, "The 256 KiB memory-map buffer was insufficient or rejected.");
    const preliminary_summary = summarizeMemory(preliminary_map);

    writeAscii(console, "  Memory descriptors: ");
    writeUsizeDecimal(console, preliminary_map.info.len);
    writeAscii(console, "\r\n  Conventional memory: ");
    writeU64Decimal(console, preliminary_summary.conventional_pages * 4096);
    writeAscii(console, " bytes\r\n\r\n");
    writeAscii(console, "Exiting UEFI boot services...\r\n");

    var final_map = boot_services.getMemoryMap(memory_map_storage[0..]) catch
        fatal(console, "Unable to capture the final UEFI memory map.");
    var attempts: u8 = 0;

    while (true) {
        const final_summary = summarizeMemory(final_map);
        boot_info.memory_map = .{
            .address = @intFromPtr(final_map.ptr),
            .descriptor_count = final_map.info.len,
            .descriptor_size = final_map.info.descriptor_size,
            .descriptor_version = final_map.info.descriptor_version,
            .total_pages = final_summary.total_pages,
            .conventional_pages = final_summary.conventional_pages,
            .highest_physical_address = final_summary.highest_physical_address,
        };

        boot_services.exitBootServices(uefi.handle, final_map.info.key) catch |err| switch (err) {
            error.InvalidParameter => {
                if (attempts >= 1) {
                    debugWrite("ExitBootServices failed twice because the memory-map key changed.\r\n");
                    zigos_halt_forever();
                }
                attempts += 1;
                final_map = boot_services.getMemoryMap(memory_map_storage[0..]) catch {
                    debugWrite("Unable to refresh the memory map after ExitBootServices rejection.\r\n");
                    zigos_halt_forever();
                };
                continue;
            },
            else => {
                debugWrite("ExitBootServices failed with an unexpected firmware status.\r\n");
                zigos_halt_forever();
            },
        };
        break;
    }

    const stack_top: [*]u8 = @ptrFromInt(boot_info.kernel_stack.base + boot_info.kernel_stack.size);
    zigos_enter_kernel(stack_top, &boot_info, &kernel.enter);
}

fn findAcpiRsdp(system_table: *uefi.tables.SystemTable) ?usize {
    var acpi_10: ?usize = null;
    const tables = system_table.configuration_table[0..system_table.number_of_table_entries];

    for (tables) |table| {
        if (uefi.Guid.eql(table.vendor_guid, ConfigurationTable.acpi_20_table_guid)) {
            return @intFromPtr(table.vendor_table);
        }
        if (uefi.Guid.eql(table.vendor_guid, ConfigurationTable.acpi_10_table_guid)) {
            acpi_10 = @intFromPtr(table.vendor_table);
        }
    }
    return acpi_10;
}

fn findFramebuffer(boot_services: *uefi.tables.BootServices) ?boot.FramebufferInfo {
    const protocol = (boot_services.locateProtocol(GraphicsOutput, null) catch return null) orelse return null;
    const mode = protocol.mode;
    const info = mode.info;

    if (mode.frame_buffer_base == 0 or mode.frame_buffer_size < 4) return null;
    if (info.pixel_format == .blt_only) return null;

    return .{
        .base = @intCast(mode.frame_buffer_base),
        .size = mode.frame_buffer_size,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pixels_per_scan_line = info.pixels_per_scan_line,
        .pixel_format = @intFromEnum(info.pixel_format),
        .red_mask = info.pixel_information.red_mask,
        .green_mask = info.pixel_information.green_mask,
        .blue_mask = info.pixel_information.blue_mask,
        .reserved_mask = info.pixel_information.reserved_mask,
    };
}

fn summarizeMemory(memory_map: MemoryMapSlice) MemorySummary {
    var summary = MemorySummary{
        .total_pages = 0,
        .conventional_pages = 0,
        .highest_physical_address = 0,
    };
    var iterator = memory_map.iterator();

    while (iterator.next()) |descriptor| {
        summary.total_pages += descriptor.number_of_pages;
        if (descriptor.type == .conventional_memory) {
            summary.conventional_pages += descriptor.number_of_pages;
        }

        const end = descriptor.physical_start + descriptor.number_of_pages * 4096;
        if (end > summary.highest_physical_address) {
            summary.highest_physical_address = end;
        }
    }
    return summary;
}

fn fatal(console: ?*uefi.protocol.SimpleTextOutput, message: []const u8) noreturn {
    if (console) |output| {
        writeAscii(output, "\r\nZigOs fatal: ");
        writeAscii(output, message);
        writeAscii(output, "\r\n");
    } else {
        debugWrite("ZigOs fatal: ");
        debugWrite(message);
        debugWrite("\r\n");
    }
    zigos_halt_forever();
}

fn writeRegister(console: *uefi.protocol.SimpleTextOutput, name: []const u8, value: u64) void {
    writeAscii(console, name);
    writeAscii(console, " = 0x");
    writeHex64(console, value);
    writeAscii(console, "\r\n");
}

fn writeHex64(console: *uefi.protocol.SimpleTextOutput, value: u64) void {
    const digits = "0123456789ABCDEF";
    var text: [16]u8 = undefined;
    var shift: u6 = 60;

    for (&text) |*character| {
        const nibble: u4 = @truncate(value >> shift);
        character.* = digits[nibble];
        if (shift == 0) break;
        shift -= 4;
    }
    writeAscii(console, &text);
}

fn writeUsizeDecimal(console: *uefi.protocol.SimpleTextOutput, value: usize) void {
    writeU64Decimal(console, @intCast(value));
}

fn writeU64Decimal(console: *uefi.protocol.SimpleTextOutput, initial_value: u64) void {
    if (initial_value == 0) {
        writeAscii(console, "0");
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
    writeAscii(console, text[index..]);
}

fn debugWrite(text: []const u8) void {
    for (text) |character| zigos_debug_putc(character);
}

fn writeAscii(console: *uefi.protocol.SimpleTextOutput, text: []const u8) void {
    debugWrite(text);

    var utf16: [512]u16 = undefined;
    const count = @min(text.len, utf16.len - 1);
    for (text[0..count], 0..) |character, index| {
        utf16[index] = character;
    }
    utf16[count] = 0;

    const terminated: [*:0]const u16 = @ptrCast(&utf16);
    _ = console.outputString(terminated) catch return;
}
