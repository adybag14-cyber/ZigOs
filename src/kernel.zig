const std = @import("std");
const boot = @import("boot_info.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const descriptor_tables = @import("descriptor_tables.zig");
const exceptions = @import("exceptions.zig");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const hpet = @import("hpet.zig");

const cc = std.os.uefi.cc;

extern fn zigos_debug_putc(character: u8) callconv(cc) void;
extern fn zigos_halt_forever() callconv(cc) noreturn;

pub fn enter(info: *const boot.BootInfo) callconv(cc) noreturn {
    debugWrite("\r\nExitBootServices succeeded.\r\n");
    debugWrite("ZigOs now owns execution without UEFI boot services.\r\n");
    debugWrite("Kernel stack: 0x");
    debugWriteHex64(@intCast(info.kernel_stack.base));
    debugWrite(" + ");
    debugWriteUsizeDecimal(info.kernel_stack.size);
    debugWrite(" bytes\r\n");

    debugWrite("Final memory descriptors: ");
    debugWriteUsizeDecimal(info.memory_map.descriptor_count);
    debugWrite("\r\nConventional memory: ");
    debugWriteU64Decimal(info.memory_map.conventional_pages * 4096);
    debugWrite(" bytes\r\nHighest physical address: 0x");
    debugWriteHex64(info.memory_map.highest_physical_address);
    debugWrite("\r\n");

    var frame_allocator = memory.FrameAllocator.init(info.memory_map);
    verifyFrameAllocator(&frame_allocator);
    installPaging(info, &frame_allocator);
    installDescriptorTables(info, &frame_allocator);
    testExceptionRecovery();

    const acpi_info = discoverAcpi(info);
    _ = initializeApic(acpi_info);
    testApicTimer(acpi_info);

    if (info.framebuffer) |framebuffer| {
        paintFramebuffer(framebuffer);
        debugWrite("Framebuffer retained and written directly at 0x");
        debugWriteHex64(@intCast(framebuffer.base));
        debugWrite("\r\n");
    } else {
        debugWrite("No writable framebuffer was retained.\r\n");
    }

    debugWrite("Milestone 0.2 reached: firmware handoff complete; kernel remains alive.\r\n");
    zigos_halt_forever();
}

fn verifyFrameAllocator(allocator: *memory.FrameAllocator) void {
    const first = allocator.allocateBelow(memory.four_gib) orelse allocatorFailure("no first frame below 4 GiB");
    const second = allocator.allocateBelow(memory.four_gib) orelse allocatorFailure("no second frame below 4 GiB");
    const third = allocator.allocateBelow(memory.four_gib) orelse allocatorFailure("no third frame below 4 GiB");

    if ((first & 0xFFF) != 0 or (second & 0xFFF) != 0 or (third & 0xFFF) != 0) {
        allocatorFailure("unaligned frame returned");
    }
    if (first == second or first == third or second == third) {
        allocatorFailure("duplicate frame returned");
    }

    verifyFramePattern(first, 0x5A49_474F_5346_5241);
    verifyFramePattern(second, 0x4D45_414C_4C4F_4332);
    verifyFramePattern(third, 0x5048_5953_4652_4D33);

    debugWrite("Physical frame allocator verified: ");
    debugWriteU64Decimal(allocator.allocated_pages);
    debugWrite(" frames at 0x");
    debugWriteHex64(@intCast(first));
    debugWrite(", 0x");
    debugWriteHex64(@intCast(second));
    debugWrite(", 0x");
    debugWriteHex64(@intCast(third));
    debugWrite("\r\n");
}

fn verifyFramePattern(address: usize, pattern: u64) void {
    const words: [*]volatile u64 = @ptrFromInt(address);
    words[0] = pattern;
    words[511] = ~pattern;

    if (words[0] != pattern or words[511] != ~pattern) {
        allocatorFailure("frame write/read verification failed");
    }
}

fn allocatorFailure(reason: []const u8) noreturn {
    debugWrite("Physical frame allocator failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn installPaging(info: *const boot.BootInfo, allocator: *memory.FrameAllocator) void {
    requireIdentityMapped("kernel entry", @intFromPtr(&enter), 1);
    requireIdentityMapped("BootInfo", @intFromPtr(info), @sizeOf(boot.BootInfo));
    requireIdentityMapped("kernel stack", info.kernel_stack.base, info.kernel_stack.size);
    requireIdentityMapped(
        "UEFI memory map",
        info.memory_map.address,
        info.memory_map.descriptor_count * info.memory_map.descriptor_size,
    );
    if (info.acpi_rsdp) |address| requireIdentityMapped("ACPI RSDP", address, 4096);
    if (info.framebuffer) |framebuffer| {
        requireIdentityMapped("framebuffer", framebuffer.base, framebuffer.size);
    }

    const installation = paging.installFourGiBIdentityMap(allocator) orelse
        pagingFailure("unable to allocate six page-table frames below 4 GiB");
    const active_cr3 = paging.currentCr3();
    const active_base = active_cr3 & ~@as(u64, 0xFFF);
    if (active_base != @as(u64, @intCast(installation.pml4_address))) {
        pagingFailure("CR3 does not contain the ZigOs PML4 address");
    }

    const post_switch_probe = allocator.allocateBelow(memory.four_gib) orelse
        pagingFailure("unable to allocate a post-switch probe frame");
    verifyFramePattern(post_switch_probe, 0x5041_4745_5442_4C33);

    debugWrite("ZigOs page tables active: CR3 0x");
    debugWriteHex64(installation.previous_cr3);
    debugWrite(" -> 0x");
    debugWriteHex64(active_cr3);
    debugWrite(", ");
    debugWriteU64Decimal(installation.mapped_bytes);
    debugWrite(" bytes identity-mapped with ");
    debugWriteU64Decimal(installation.table_pages);
    debugWrite(" table pages\r\n");
    debugWrite("Post-switch frame verified at 0x");
    debugWriteHex64(@intCast(post_switch_probe));
    debugWrite("\r\n");
}

fn requireIdentityMapped(name: []const u8, start: usize, size: usize) void {
    const limit: usize = @intCast(memory.four_gib);
    if (start >= limit or size > limit - start) {
        debugWrite("Cannot install 4 GiB identity map: ");
        debugWrite(name);
        debugWrite(" lies outside the safe bootstrap range.\r\n");
        zigos_halt_forever();
    }
}

fn pagingFailure(reason: []const u8) noreturn {
    debugWrite("Paging installation failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn installDescriptorTables(info: *const boot.BootInfo, allocator: *memory.FrameAllocator) void {
    const kernel_stack_top = info.kernel_stack.base + info.kernel_stack.size;
    const installation = descriptor_tables.install(allocator, kernel_stack_top) orelse
        descriptorTableFailure("GDT/TSS/IDT installation or breakpoint verification failed");

    debugWrite("Descriptor tables active: GDT 0x");
    debugWriteHex64(@intCast(installation.gdt_address));
    debugWrite(", TSS 0x");
    debugWriteHex64(@intCast(installation.tss_address));
    debugWrite(", IDT 0x");
    debugWriteHex64(@intCast(installation.idt_address));
    debugWrite("\r\n");
    debugWrite("Segments verified: CS=0x");
    debugWriteHex16(installation.code_segment);
    debugWrite(", TR=0x");
    debugWriteHex16(installation.task_register);
    debugWrite("\r\n");
    debugWrite("Breakpoint interrupt handled on IST1 at 0x");
    debugWriteHex64(@intCast(installation.breakpoint_stack_pointer));
    debugWrite(" within stack 0x");
    debugWriteHex64(@intCast(installation.interrupt_stack_base));
    debugWrite(" + ");
    debugWriteUsizeDecimal(installation.interrupt_stack_size);
    debugWrite(" bytes\r\n");
}

fn descriptorTableFailure(reason: []const u8) noreturn {
    debugWrite("Descriptor-table failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn discoverAcpi(info: *const boot.BootInfo) acpi.Discovery {
    const rsdp_address = info.acpi_rsdp orelse acpiFailure("firmware did not provide an RSDP");
    const discovery = acpi.discover(rsdp_address) orelse
        acpiFailure("RSDP/root-table signature, bounds, or checksum validation failed");

    debugWrite("ACPI verified: revision ");
    debugWriteU64Decimal(discovery.revision);
    debugWrite(", ");
    debugWrite(switch (discovery.root_kind) {
        .xsdt => "XSDT",
        .rsdt => "RSDT",
    });
    debugWrite(" at 0x");
    debugWriteHex64(@intCast(discovery.root_address));
    debugWrite(", valid tables ");
    debugWriteUsizeDecimal(discovery.valid_table_count);
    debugWrite(", rejected tables ");
    debugWriteUsizeDecimal(discovery.invalid_table_count);
    debugWrite("\r\n");

    if (discovery.madt) |madt| {
        debugWrite("MADT topology: ");
        debugWriteU64Decimal(madt.processor_count);
        debugWrite(" processors, ");
        debugWriteU64Decimal(madt.io_apic_count);
        debugWrite(" IOAPICs, ");
        debugWriteU64Decimal(madt.interrupt_override_count);
        debugWrite(" overrides\r\n");
        debugWrite("Local APIC at 0x");
        debugWriteHex64(madt.local_apic_address);
        if (madt.first_io_apic_address) |address| {
            debugWrite(", first IOAPIC at 0x");
            debugWriteHex64(address);
        }
        debugWrite(if (madt.legacy_pic_compatible) ", legacy PIC compatible\r\n" else ", no legacy PIC flag\r\n");
    } else {
        debugWrite("MADT was not present in the validated ACPI tables.\r\n");
    }

    printOptionalTable("MCFG", discovery.mcfg_address);
    printOptionalTable("HPET", discovery.hpet_address);
    printOptionalTable("FACP", discovery.facp_address);
    return discovery;
}

fn printOptionalTable(name: []const u8, address: ?usize) void {
    debugWrite(name);
    if (address) |table_address| {
        debugWrite(" at 0x");
        debugWriteHex64(@intCast(table_address));
    } else {
        debugWrite(" not present");
    }
    debugWrite("\r\n");
}

fn acpiFailure(reason: []const u8) noreturn {
    debugWrite("ACPI discovery failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn initializeApic(discovery: acpi.Discovery) apic.Information {
    const madt = discovery.madt orelse apicFailure("validated ACPI did not contain a MADT");
    const information = apic.initialize(madt) orelse
        apicFailure("local APIC enablement or register verification failed");

    debugWrite("Local APIC enabled: ");
    debugWrite(if (information.x2apic) "x2APIC" else "xAPIC");
    debugWrite(" ID ");
    debugWriteU64Decimal(information.apic_id);
    debugWrite(", version 0x");
    debugWriteHex16(information.version);
    debugWrite(", max LVT ");
    debugWriteU64Decimal(information.maximum_lvt_entry);
    debugWrite(", base 0x");
    debugWriteHex64(information.base_address);
    debugWrite("\r\n");
    debugWrite("APIC SVR verified at 0x");
    debugWriteHex64(information.spurious_vector_register);
    debugWrite(if (information.legacy_pic_masked)
        "; legacy PIC fully masked\r\n"
    else if (madt.legacy_pic_compatible)
        "; legacy PIC mask verification failed\r\n"
    else
        "; platform has no legacy PIC compatibility flag\r\n");

    if (madt.legacy_pic_compatible and !information.legacy_pic_masked) {
        apicFailure("8259 PIC mask registers did not retain 0xFF");
    }
    return information;
}

fn apicFailure(reason: []const u8) noreturn {
    debugWrite("APIC initialization failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn testApicTimer(discovery: acpi.Discovery) void {
    const table_address = discovery.hpet_address orelse timerFailure("ACPI did not expose an HPET table");
    const device = hpet.initialize(table_address) orelse
        timerFailure("HPET table or MMIO capability validation failed");

    debugWrite("HPET active: base 0x");
    debugWriteHex64(@intCast(device.base_address));
    debugWrite(", period ");
    debugWriteU64Decimal(device.period_femtoseconds);
    debugWrite(" fs, timers ");
    debugWriteU64Decimal(device.timer_count);
    debugWrite(if (device.counter_64_bit) ", 64-bit counter\r\n" else ", 32-bit counter\r\n");

    const result = apic.calibrateAndTestTimer(device) orelse
        timerFailure("APIC timer calibration or interrupt wake-up failed");
    debugWrite("APIC timer calibrated: ");
    debugWriteU64Decimal(result.ticks_per_second);
    debugWrite(" ticks/s, one-shot count ");
    debugWriteU64Decimal(result.initial_count);
    debugWrite("\r\n");
    debugWrite("Maskable interrupt vector 0x0040 handled ");
    debugWriteU64Decimal(result.interrupt_count);
    debugWrite(" time(s), EOI acknowledged\r\n");
}

fn timerFailure(reason: []const u8) noreturn {
    debugWrite("Timer initialization failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn testExceptionRecovery() void {
    const result = exceptions.testInvalidOpcodeRecovery() orelse
        exceptionTestFailure("UD2 did not return through the generic exception path");
    if (result.resumed_rip != result.fault_rip + 2) {
        exceptionTestFailure("invalid-opcode handler did not advance RIP by two bytes");
    }

    debugWrite("CPU exception coverage active: vectors 0-31 installed on IST1\r\n");
    debugWrite("Invalid-opcode exception recovered: vector ");
    debugWriteU64Decimal(result.vector);
    debugWrite(", error 0x");
    debugWriteHex64(result.error_code);
    debugWrite(", RIP 0x");
    debugWriteHex64(result.fault_rip);
    debugWrite(" -> 0x");
    debugWriteHex64(result.resumed_rip);
    debugWrite("\r\n");
}

fn exceptionTestFailure(reason: []const u8) noreturn {
    debugWrite("Exception-path verification failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn paintFramebuffer(framebuffer: boot.FramebufferInfo) void {
    if (framebuffer.base == 0 or framebuffer.size < 4) return;
    if (framebuffer.pixel_format == 3) return;

    const rows: u32 = @min(framebuffer.height, 48);
    const columns: u32 = @min(framebuffer.width, framebuffer.pixels_per_scan_line);
    const maximum_pixels = framebuffer.size / @sizeOf(u32);
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);

    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        var x: u32 = 0;
        while (x < columns) : (x += 1) {
            const index = @as(usize, y) * @as(usize, framebuffer.pixels_per_scan_line) + @as(usize, x);
            if (index >= maximum_pixels) return;

            const red: u8 = @intCast(32 + ((x * 191) / @max(columns, 1)));
            const green: u8 = @intCast(24 + ((y * 160) / @max(rows, 1)));
            const blue: u8 = 112;
            pixels[index] = encodePixel(framebuffer, red, green, blue);
        }
    }
}

fn encodePixel(framebuffer: boot.FramebufferInfo, red: u8, green: u8, blue: u8) u32 {
    return switch (framebuffer.pixel_format) {
        0 => @as(u32, red) | (@as(u32, green) << 8) | (@as(u32, blue) << 16),
        1 => @as(u32, blue) | (@as(u32, green) << 8) | (@as(u32, red) << 16),
        2 => channelToMask(red, framebuffer.red_mask) |
            channelToMask(green, framebuffer.green_mask) |
            channelToMask(blue, framebuffer.blue_mask),
        else => 0,
    };
}

fn channelToMask(value: u8, mask: u32) u32 {
    if (mask == 0) return 0;

    const shift: u5 = @intCast(@ctz(mask));
    const normalized_mask = mask >> shift;
    const width: u6 = @intCast(32 - @clz(normalized_mask));
    const maximum: u64 = (@as(u64, 1) << width) - 1;
    const scaled: u32 = @intCast((@as(u64, value) * maximum) / 255);
    return (scaled << shift) & mask;
}

fn debugWrite(text: []const u8) void {
    for (text) |character| zigos_debug_putc(character);
}

fn debugWriteHex16(value: u16) void {
    const digits = "0123456789ABCDEF";
    var text: [4]u8 = undefined;
    var shift: u4 = 12;

    for (&text) |*character| {
        const nibble: u4 = @truncate(value >> shift);
        character.* = digits[nibble];
        if (shift == 0) break;
        shift -= 4;
    }
    debugWrite(&text);
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

fn debugWriteUsizeDecimal(value: usize) void {
    debugWriteU64Decimal(@intCast(value));
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
