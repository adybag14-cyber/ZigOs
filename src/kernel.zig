const std = @import("std");
const boot = @import("boot_info.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const descriptor_tables = @import("descriptor_tables.zig");
const exceptions = @import("exceptions.zig");
const stack_trace = @import("stack_trace.zig");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const ioapic = @import("ioapic.zig");
const keyboard_input = @import("input.zig");
const pit = @import("pit.zig");
const ps2 = @import("ps2.zig");
const pci = @import("pci.zig");
const ahci = @import("ahci.zig");
const nvme = @import("nvme.zig");
const partition = @import("partition.zig");
const gpt = @import("gpt.zig");
const fat = @import("fat.zig");
const pe = @import("pe.zig");
const heap = @import("heap.zig");
const scheduler = @import("scheduler.zig");
const preemptive = @import("preemptive.zig");
const user_mode = @import("user_mode.zig");
const xhci = @import("xhci.zig");
const e1000e = @import("e1000e.zig");
const smp = @import("smp.zig");
const serial = @import("serial.zig");
const shell = @import("shell.zig");
const framebuffer_console = @import("framebuffer_console.zig");
const time_reference = @import("time_reference.zig");

const cc = std.os.uefi.cc;
const cursor_pixel_count: usize = 20;

const TimerSetup = struct {
    result: apic.TimerResult,
    reference: time_reference.Reference,
};

var normalized_memory_layout: memory.Layout = undefined;
var kernel_heap: heap.Heap = undefined;
var kernel_heap_ready: bool = false;

var cooperative_trace: [12]u8 = @splat(0);
var cooperative_trace_length: usize = 0;
var cooperative_task_a_count: u64 = 0;
var cooperative_task_b_count: u64 = 0;
var preemptive_task_a_iterations: u64 = 0;
var preemptive_task_b_iterations: u64 = 0;

extern fn zigos_debug_putc(character: u8) callconv(cc) void;
extern fn zigos_halt_forever() callconv(cc) noreturn;
extern fn zigos_high_half_probe() callconv(cc) usize;

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

    normalized_memory_layout = memory.parseLayout(info.memory_map) orelse
        memoryLayoutFailure("retained UEFI descriptors could not be normalized");
    verifyMemoryLayout(info, &normalized_memory_layout);
    var frame_allocator = memory.FrameAllocator.init(&normalized_memory_layout);
    verifyFrameAllocator(&frame_allocator);
    installPaging(info, &frame_allocator);
    installDescriptorTables(info, &frame_allocator);
    testExceptionRecovery(info);
    initializeSerial();

    const acpi_info = discoverAcpi(info);
    const local_apic_info = initializeApic(acpi_info);
    const timer_setup = testApicTimer(acpi_info);
    const legacy_irq_target = startApplicationProcessors(
        info,
        &frame_allocator,
        acpi_info,
        local_apic_info,
        timer_setup.reference,
        timer_setup.result.ticks_per_second,
    );
    const io_apic_info = initializeIoApic(acpi_info);
    var ps2_keyboard_ready = false;
    if (legacy_irq_target) |destination_apic_id| {
        debugWrite("Legacy IRQ target selected: APIC ");
        debugWriteU64Decimal(destination_apic_id);
        debugWrite(if (destination_apic_id == local_apic_info.apic_id)
            " (bootstrap processor)\r\n"
        else
            " (application processor)\r\n");
        testExternalIrq(acpi_info, destination_apic_id, io_apic_info, timer_setup.reference);
        ps2_keyboard_ready = testPs2KeyboardIrq(
            acpi_info,
            destination_apic_id,
            io_apic_info,
            timer_setup.reference,
        );
    } else {
        debugWrite("Legacy IRQ routing unavailable: no online APIC ID fits the IOAPIC destination field\r\n");
    }
    debugWrite("Legacy input ready: PS/2 keyboard ");
    debugWrite(if (ps2_keyboard_ready) "yes" else "no");
    debugWrite("\r\n");
    var graphical_console_storage: ?framebuffer_console.Console = null;
    if (info.framebuffer) |framebuffer| {
        graphical_console_storage = framebuffer_console.Console.init(framebuffer);
        if (graphical_console_storage) |*graphical_console| {
            const initial_console_report = graphical_console.report();
            if (!initial_console_report.cursor_visible or
                initial_console_report.cursor_draws != 6 or
                initial_console_report.cursor_erases != 5 or
                initial_console_report.display_lit_pixels != initial_console_report.lit_pixels + cursor_pixel_count or
                initial_console_report.display_checksum != 0x7CF7_2F9A_F061_C761)
            {
                framebufferConsoleFailure("initial framebuffer cursor overlay was not deterministic");
            }
            debugWrite("Framebuffer terminal initialized: ");
            debugWriteUsizeDecimal(initial_console_report.width);
            debugWrite("x");
            debugWriteUsizeDecimal(initial_console_report.height);
            debugWrite(", cells ");
            debugWriteUsizeDecimal(initial_console_report.columns);
            debugWrite("x");
            debugWriteUsizeDecimal(initial_console_report.rows);
            debugWrite(", cursor row ");
            debugWriteUsizeDecimal(initial_console_report.cursor_row);
            debugWrite(", column ");
            debugWriteUsizeDecimal(initial_console_report.cursor_column);
            debugWrite(", writes ");
            debugWriteUsizeDecimal(initial_console_report.writes);
            debugWrite(", cursor ");
            debugWrite(if (initial_console_report.cursor_visible) "visible" else "hidden");
            debugWrite(", draws ");
            debugWriteUsizeDecimal(initial_console_report.cursor_draws);
            debugWrite(", erases ");
            debugWriteUsizeDecimal(initial_console_report.cursor_erases);
            debugWrite(", display checksum 0x");
            debugWriteHex64(initial_console_report.display_checksum);
            debugWrite("\r\n");
        } else {
            debugWrite("GOP framebuffer geometry or pixel format unsupported; continuing with serial diagnostics only\r\n");
        }
    } else {
        debugWrite("GOP framebuffer unavailable; continuing with serial diagnostics only\r\n");
    }

    const pci_inventory = enumeratePci(acpi_info);
    const network_ready = inspectE1000e(
        pci_inventory,
        &frame_allocator,
        legacy_irq_target,
    );
    const graphical_console: ?*framebuffer_console.Console = if (graphical_console_storage) |*console|
        console
    else
        null;
    const usb_keyboard_ready = inspectXhci(
        pci_inventory,
        &frame_allocator,
        graphical_console,
        legacy_irq_target,
    );
    const nvme_storage_ready = inspectNvme(
        pci_inventory,
        &frame_allocator,
        timer_setup.reference,
        legacy_irq_target,
    );
    const ahci_storage_ready = inspectAhci(pci_inventory, &frame_allocator, legacy_irq_target);
    if (!nvme_storage_ready and !ahci_storage_ready) {
        storageFailure("no supported NVMe namespace or SATA device was usable");
    }
    debugWrite("Interactive input ready: USB keyboard ");
    debugWrite(if (usb_keyboard_ready) "yes" else "no");
    debugWrite("\r\n");
    debugWrite("Storage backends ready: NVMe ");
    debugWrite(if (nvme_storage_ready) "yes" else "no");
    debugWrite(", AHCI ");
    debugWrite(if (ahci_storage_ready) "yes" else "no");
    debugWrite("\r\n");
    debugWrite("Network interfaces ready: Intel 82574L ");
    debugWrite(if (network_ready) "yes" else "no");
    debugWrite("\r\n");
    initializeKernelHeap(&frame_allocator);
    testCooperativeScheduler(&frame_allocator);
    testPreemptiveScheduler(&frame_allocator, timer_setup.result.ticks_per_second);
    testUserMode(&frame_allocator);

    if (graphical_console) |console| {
        const report = console.report();
        debugWrite("Framebuffer console active: ");
        debugWriteUsizeDecimal(report.width);
        debugWrite("x");
        debugWriteUsizeDecimal(report.height);
        debugWrite(", stride ");
        debugWriteUsizeDecimal(report.stride);
        debugWrite(", lines ");
        debugWriteUsizeDecimal(report.lines);
        debugWrite(", glyphs ");
        debugWriteUsizeDecimal(report.glyphs);
        debugWrite(", resets ");
        debugWriteUsizeDecimal(report.resets);
        debugWrite(", lit pixels ");
        debugWriteUsizeDecimal(report.lit_pixels);
        debugWrite(", checksum 0x");
        debugWriteHex64(report.checksum);
        debugWrite(", cursor ");
        debugWrite(if (report.cursor_visible) "visible" else "hidden");
        debugWrite(", draws ");
        debugWriteUsizeDecimal(report.cursor_draws);
        debugWrite(", erases ");
        debugWriteUsizeDecimal(report.cursor_erases);
        debugWrite(", display lit pixels ");
        debugWriteUsizeDecimal(report.display_lit_pixels);
        debugWrite(", display checksum 0x");
        debugWriteHex64(report.display_checksum);
        debugWrite("\r\n");
        if (usb_keyboard_ready) {
            debugWrite("Framebuffer transcript: clear, error recovery, and Up-arrow history recall\r\n");
        } else {
            debugWrite("Framebuffer transcript: startup prompt; USB keyboard unavailable\r\n");
        }
        debugWrite("Framebuffer retained and written directly at 0x");
        debugWriteHex64(@intCast(info.framebuffer.?.base));
        debugWrite("\r\n");
    } else {
        debugWrite("Framebuffer console unavailable; serial-only diagnostics active\r\n");
    }

    debugWrite("ZigOs boot sequence complete: kernel foundations and hardware probes passed.\r\n");
    zigos_halt_forever();
}

fn verifyMemoryLayout(info: *const boot.BootInfo, layout: *const memory.Layout) void {
    const expected_usable_bytes = info.memory_map.conventional_pages *| memory.page_size;
    if (layout.descriptor_count != info.memory_map.descriptor_count or
        layout.usable_bytes != expected_usable_bytes or
        layout.highest_address != info.memory_map.highest_physical_address or
        layout.region_count == 0 or
        layout.region_count > layout.descriptor_count)
    {
        memoryLayoutFailure("normalized totals do not match the retained UEFI map");
    }

    requireNotUsable(layout, "kernel code", @intFromPtr(&enter), 1);
    requireNotUsable(layout, "kernel stack", info.kernel_stack.base, info.kernel_stack.size);
    requireNotUsable(
        layout,
        "UEFI memory map",
        info.memory_map.address,
        info.memory_map.descriptor_count * info.memory_map.descriptor_size,
    );
    requireNotUsable(layout, "AP trampoline", info.ap_trampoline.base, info.ap_trampoline.size);
    if (info.acpi_rsdp) |address| requireNotUsable(layout, "ACPI RSDP", address, 36);
    if (info.framebuffer) |framebuffer| {
        requireNotUsable(layout, "framebuffer", framebuffer.base, framebuffer.size);
    }

    debugWrite("Memory layout normalized: ");
    debugWriteUsizeDecimal(layout.descriptor_count);
    debugWrite(" descriptors -> ");
    debugWriteUsizeDecimal(layout.region_count);
    debugWrite(" regions; usable ");
    debugWriteU64Decimal(layout.usable_bytes);
    debugWrite(" bytes in ");
    debugWriteUsizeDecimal(layout.usable_region_count);
    debugWrite(" descriptors, reclaimable ");
    debugWriteU64Decimal(layout.reclaimable_bytes);
    debugWrite(", runtime ");
    debugWriteU64Decimal(layout.runtime_bytes);
    debugWrite(", ACPI NVS ");
    debugWriteU64Decimal(layout.acpi_nvs_bytes);
    debugWrite(", MMIO ");
    debugWriteU64Decimal(layout.mmio_bytes);
    debugWrite(", reserved ");
    debugWriteU64Decimal(layout.reserved_bytes);
    debugWrite(" bytes\r\n");
    debugWrite("Protected memory verified: kernel code, kernel stack, UEFI memory map, AP trampoline, ACPI RSDP and framebuffer excluded from allocator\r\n");
}

fn requireNotUsable(layout: *const memory.Layout, label: []const u8, base: usize, size: usize) void {
    if (size == 0 or layout.overlapsUsable(base, size)) {
        debugWrite("Memory-layout protection failure for ");
        debugWrite(label);
        debugWrite(" at 0x");
        debugWriteHex64(@intCast(base));
        debugWrite(" + ");
        debugWriteUsizeDecimal(size);
        debugWrite(" bytes\r\n");
        zigos_halt_forever();
    }
}

fn memoryLayoutFailure(reason: []const u8) noreturn {
    debugWrite("Memory-layout normalization failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
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
    verifyHigherHalfAlias(post_switch_probe);

    debugWrite("ZigOs page tables active: CR3 0x");
    debugWriteHex64(installation.previous_cr3);
    debugWrite(" -> 0x");
    debugWriteHex64(active_cr3);
    debugWrite(", ");
    debugWriteU64Decimal(installation.mapped_bytes);
    debugWrite(" bytes identity-mapped with ");
    debugWriteU64Decimal(installation.table_pages);
    debugWrite(" table pages\r\n");
    debugWrite("Higher-half mirror base 0x");
    debugWriteHex64(installation.higher_half_base);
    debugWrite(" maps the same ");
    debugWriteU64Decimal(installation.mapped_bytes);
    debugWrite(" physical bytes\r\n");
    debugWrite("Post-switch frame verified at 0x");
    debugWriteHex64(@intCast(post_switch_probe));
    debugWrite("\r\n");
}

fn verifyHigherHalfAlias(physical_frame: usize) void {
    const high_frame_address = paging.higherHalfAlias(physical_frame) orelse
        pagingFailure("physical probe frame was outside the higher-half mirror");
    if (!paging.isHigherHalfAddress(high_frame_address)) {
        pagingFailure("higher-half data alias was not canonical-high");
    }

    const low_words: [*]volatile u64 = @ptrFromInt(physical_frame);
    const high_words: [*]volatile u64 = @ptrFromInt(high_frame_address);
    if (high_words[0] != 0x5041_4745_5442_4C33 or high_words[511] != ~@as(u64, 0x5041_4745_5442_4C33)) {
        pagingFailure("higher-half alias could not read the low-address frame pattern");
    }

    high_words[1] = 0x4849_4748_4441_5441;
    if (low_words[1] != 0x4849_4748_4441_5441) {
        pagingFailure("higher-half write was not visible through the identity mapping");
    }

    const low_code_address = @intFromPtr(&zigos_high_half_probe);
    if (low_code_address >= memory.four_gib) {
        pagingFailure("high-half probe code was linked outside the mirrored bootstrap range");
    }
    const high_code_address = paging.higherHalfAlias(low_code_address) orelse
        pagingFailure("unable to create a higher-half code alias");
    const high_probe: *const fn () callconv(cc) usize = @ptrFromInt(high_code_address);
    const observed_address = high_probe();
    if (observed_address != high_code_address) {
        pagingFailure("RIP-relative execution did not observe the higher-half code address");
    }

    debugWrite("Higher-half data alias verified: physical 0x");
    debugWriteHex64(@intCast(physical_frame));
    debugWrite(" <-> virtual 0x");
    debugWriteHex64(@intCast(high_frame_address));
    debugWrite("\r\n");
    debugWrite("Higher-half code execution verified: low 0x");
    debugWriteHex64(@intCast(low_code_address));
    debugWrite(" -> high RIP 0x");
    debugWriteHex64(@intCast(observed_address));
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
        debugWrite("MADT processor IDs:");
        for (madt.processors[0..madt.stored_processor_count]) |processor| {
            debugWrite(" ");
            debugWriteU64Decimal(processor.apic_id);
            debugWrite(if (processor.x2apic) "(x2)" else "(xAPIC)");
        }
        debugWrite("\r\n");
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

fn testApicTimer(discovery: acpi.Discovery) TimerSetup {
    const reference = time_reference.Reference.initialize(discovery.hpet_address) orelse
        timerFailure("neither HPET nor PIT channel 2 could provide a reference clock");

    switch (reference.kind) {
        .hpet => {
            debugWrite("HPET active: base 0x");
            debugWriteHex64(@intCast(reference.baseAddress()));
            debugWrite(", period ");
            debugWriteU64Decimal(reference.periodFemtoseconds());
            debugWrite(" fs, timers ");
            debugWriteU64Decimal(reference.timerCount());
            debugWrite(if (reference.counter64Bit()) ", 64-bit counter\r\n" else ", 32-bit counter\r\n");
        },
        .pit_channel2 => {
            debugWrite("PIT channel 2 reference active: 1193182 Hz polled one-shot, no IRQ route\r\n");
        },
    }

    const result = apic.calibrateAndTestTimer(reference) orelse
        timerFailure("APIC timer calibration or interrupt wake-up failed");
    debugWrite("APIC timer calibrated with ");
    debugWrite(reference.sourceName());
    debugWrite(": ");
    debugWriteU64Decimal(result.ticks_per_second);
    debugWrite(" ticks/s, one-shot count ");
    debugWriteU64Decimal(result.initial_count);
    debugWrite("\r\n");
    debugWrite("Maskable interrupt vector 0x0040 handled ");
    debugWriteU64Decimal(result.interrupt_count);
    debugWrite(" time(s), EOI acknowledged\r\n");
    return .{
        .result = result,
        .reference = reference,
    };
}

fn timerFailure(reason: []const u8) noreturn {
    debugWrite("Timer initialization failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn testExceptionRecovery(info: *const boot.BootInfo) void {
    stack_trace.reset();
    if (!stack_trace.registerStackRange(info.kernel_stack.base, info.kernel_stack.size)) {
        exceptionTestFailure("kernel stack could not be registered for unwinding");
    }
    const result = exceptions.testInvalidOpcodeRecovery() orelse
        exceptionTestFailure("UD2 did not return through the generic exception path");
    if (result.resumed_rip != result.fault_rip + 2) {
        exceptionTestFailure("invalid-opcode handler did not advance RIP by two bytes");
    }
    const expected_symbols = [_][]const u8{
        "zigos_trigger_ud2",
        "exceptions.traceProbeLevel3",
        "exceptions.traceProbeLevel2",
        "exceptions.traceProbeLevel1",
    };
    if (result.trace.frame_count < expected_symbols.len or
        result.trace.symbolized_count < expected_symbols.len)
    {
        exceptionTestFailure("exception RBP chain did not yield four symbolized frames");
    }
    for (expected_symbols, 0..) |expected, index| {
        if (!stack_trace.frameHasSymbol(result.trace.frames[index], expected)) {
            exceptionTestFailure("symbolized exception frame order was incorrect");
        }
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
    debugWrite("Symbolized exception stack trace: ");
    for (result.trace.frames[0..expected_symbols.len], 0..) |frame, index| {
        if (index != 0) debugWrite(" <- ");
        debugWrite("#");
        debugWriteUsizeDecimal(index);
        debugWrite(" ");
        debugWrite(frame.symbol_name.?);
        debugWrite("+0x");
        debugWriteHex64(frame.symbol_offset);
    }
    debugWrite("; ");
    debugWriteUsizeDecimal(result.trace.symbolized_count);
    debugWrite("/");
    debugWriteUsizeDecimal(result.trace.frame_count);
    debugWrite(" frames symbolized\r\n");
}

fn exceptionTestFailure(reason: []const u8) noreturn {
    debugWrite("Exception-path verification failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn initializeIoApic(discovery: acpi.Discovery) ioapic.Information {
    const madt = discovery.madt orelse ioApicFailure("validated ACPI did not contain a MADT");
    const information = ioapic.initialize(madt) orelse
        ioApicFailure("IOAPIC register discovery or redirection masking failed");

    debugWrite("IOAPIC initialized: ID ");
    debugWriteU64Decimal(information.io_apic_id);
    debugWrite(", version 0x");
    debugWriteHex16(information.version);
    debugWrite(", base 0x");
    debugWriteHex64(@intCast(information.base_address));
    debugWrite(", GSI ");
    debugWriteU64Decimal(information.global_system_interrupt_base);
    debugWrite("-");
    debugWriteU64Decimal(
        information.global_system_interrupt_base + information.redirection_entries - 1,
    );
    debugWrite("\r\n");
    debugWrite("IOAPIC redirection table fully masked: ");
    debugWriteU64Decimal(information.redirection_entries);
    debugWrite(" entries, first 0x");
    debugWriteHex64(information.first_redirection_low);
    debugWrite(", last 0x");
    debugWriteHex64(information.last_redirection_low);
    debugWrite("\r\n");

    var index: usize = 0;
    while (index < madt.stored_override_count) : (index += 1) {
        const override = madt.overrides[index];
        debugWrite("ISA override: IRQ ");
        debugWriteU64Decimal(override.irq_source);
        debugWrite(" -> GSI ");
        debugWriteU64Decimal(override.global_system_interrupt);
        debugWrite(", flags 0x");
        debugWriteHex16(override.flags);
        debugWrite("\r\n");
    }
    return information;
}

fn testExternalIrq(
    discovery: acpi.Discovery,
    destination_apic_id: u8,
    information: ioapic.Information,
    reference: time_reference.Reference,
) void {
    const vector: u8 = 0x44;
    const milliseconds: u32 = 10;
    const madt = discovery.madt orelse ioApicFailure("validated ACPI did not contain a MADT");
    var selected_override: ?acpi.InterruptOverride = null;
    for (madt.overrides[0..madt.stored_override_count]) |override| {
        if (override.bus_source == 0 and override.irq_source == 0) {
            selected_override = override;
            break;
        }
    }
    const override = selected_override orelse
        ioApicFailure("MADT did not expose the ISA IRQ0 override required by this proof");
    pit.reset();
    const route = ioapic.route(
        information,
        override.global_system_interrupt,
        vector,
        destination_apic_id,
        override.flags,
    ) orelse ioApicFailure("IOAPIC IRQ0 route programming or readback failed");
    const divisor = pit.armOneShotMilliseconds(milliseconds) orelse
        ioApicFailure("PIT one-shot divisor was invalid");
    if (destination_apic_id == apic.currentId()) {
        pit.waitForInterrupt();
    } else if (!waitForPitInterruptCount(reference, 1)) {
        ioApicFailure("PIT IRQ0 did not arrive exactly once at the selected CPU");
    }
    if (pit.count() != 1) ioApicFailure("PIT IRQ0 did not arrive exactly once");
    if (!ioapic.mask(information, override.global_system_interrupt)) {
        ioApicFailure("IOAPIC IRQ0 route could not be remasked after EOI");
    }
    debugWrite("External IRQ routed: ISA IRQ 0 -> GSI ");
    debugWriteU64Decimal(route.global_system_interrupt);
    debugWrite(" -> vector 0x");
    debugWriteHex8(route.vector);
    debugWrite(", target APIC ");
    debugWriteU64Decimal(route.destination_apic_id);
    debugWrite(", PIT divisor ");
    debugWriteU64Decimal(divisor);
    debugWrite(", count ");
    debugWriteU64Decimal(pit.count());
    debugWrite(", active-");
    debugWrite(if (route.active_low) "low" else "high");
    debugWrite(", ");
    debugWrite(if (route.level_triggered) "level" else "edge");
    debugWrite(", remasked after EOI\r\n");
}

fn testPs2KeyboardIrq(
    discovery: acpi.Discovery,
    destination_apic_id: u8,
    information: ioapic.Information,
    reference: time_reference.Reference,
) bool {
    const vector: u8 = 0x45;
    const isa_irq: u8 = 1;
    const injected_scan_code: u8 = 0x1E;
    const madt = discovery.madt orelse ioApicFailure("validated ACPI did not contain a MADT");
    var global_system_interrupt: u32 = isa_irq;
    var flags: u16 = 0;
    for (madt.overrides[0..madt.stored_override_count]) |override| {
        if (override.bus_source == 0 and override.irq_source == isa_irq) {
            global_system_interrupt = override.global_system_interrupt;
            flags = override.flags;
            break;
        }
    }

    const configuration = ps2.prepareKeyboardIrq() orelse {
        debugWrite("i8042/PS2 controller unavailable; continuing without legacy keyboard input\r\n");
        return false;
    };
    const route = ioapic.route(
        information,
        global_system_interrupt,
        vector,
        destination_apic_id,
        flags,
    ) orelse ioApicFailure("IOAPIC keyboard IRQ route programming or readback failed");
    if (!ps2.injectKeyboardScanCode(injected_scan_code)) {
        ioApicFailure("i8042 keyboard make-code injection failed");
    }
    if (destination_apic_id == apic.currentId()) {
        ps2.waitForInterrupt();
    } else if (!waitForPs2InterruptCount(reference, 1)) {
        ioApicFailure("PS/2 keyboard make interrupt did not reach the selected CPU");
    }
    if (ps2.count() != 1 or ps2.scanCode() != injected_scan_code) {
        ioApicFailure("PS/2 keyboard make interrupt did not return scan code 0x1E");
    }
    const captured_make = ps2.scanCode();
    const injected_break_code: u8 = injected_scan_code | 0x80;
    if (!ps2.injectKeyboardScanCode(injected_break_code)) {
        ioApicFailure("i8042 keyboard break-code injection failed");
    }
    if (destination_apic_id == apic.currentId()) {
        ps2.waitForInterrupt();
    } else if (!waitForPs2InterruptCount(reference, 2)) {
        ioApicFailure("PS/2 keyboard break interrupt did not reach the selected CPU");
    }
    if (ps2.count() != 2 or ps2.scanCode() != injected_break_code) {
        ioApicFailure("PS/2 keyboard break interrupt did not return scan code 0x9E");
    }
    const captured_break = ps2.scanCode();
    if (!ioapic.mask(information, global_system_interrupt)) {
        ioApicFailure("IOAPIC keyboard route could not be remasked after EOI");
    }
    if (!ps2.restoreConfiguration(configuration)) {
        ioApicFailure("i8042 configuration byte could not be restored");
    }

    var event_queue = keyboard_input.Queue.init();
    if (!event_queue.applyPs2Set1(captured_make) or
        !event_queue.applyPs2Set1(captured_break) or
        event_queue.count() != 2 or event_queue.dropped != 0)
    {
        ioApicFailure("PS/2 make/break codes did not enter the common keyboard queue");
    }
    const press_event = event_queue.pop() orelse
        ioApicFailure("PS/2 press event was missing from the common queue");
    const release_event = event_queue.pop() orelse
        ioApicFailure("PS/2 release event was missing from the common queue");
    if (press_event.sequence != 1 or press_event.source != .ps2 or
        press_event.action != .pressed or press_event.usage != 0x04 or press_event.ascii != 'a' or
        release_event.sequence != 2 or release_event.source != .ps2 or
        release_event.action != .released or release_event.usage != 0x04 or release_event.ascii != 'a' or
        event_queue.pop() != null)
    {
        ioApicFailure("PS/2 keyboard event translation or ordering failed");
    }

    debugWrite("PS/2 keyboard IRQ verified: ISA IRQ 1 -> GSI ");
    debugWriteU64Decimal(route.global_system_interrupt);
    debugWrite(" -> vector 0x");
    debugWriteHex8(route.vector);
    debugWrite(", make 0x");
    debugWriteHex8(captured_make);
    debugWrite(", break 0x");
    debugWriteHex8(captured_break);
    debugWrite(", count ");
    debugWriteU64Decimal(ps2.count());
    debugWrite(", command byte 0x");
    debugWriteHex8(configuration.active);
    debugWrite(", target APIC ");
    debugWriteU64Decimal(route.destination_apic_id);
    debugWrite(", remasked and restored after EOI\r\n");
    debugWrite("PS/2 event queue verified: #1 usage 0x04 pressed -> 'a'; #2 usage 0x04 released -> 'a'; dropped 0\r\n");
    return true;
}

fn waitForPitInterruptCount(reference: time_reference.Reference, expected: u32) bool {
    var attempts: usize = 0;
    while (pit.count() < expected and attempts < 1_000) : (attempts += 1) {
        if (!reference.waitNanoseconds(100_000)) return false;
    }
    return pit.count() == expected;
}

fn waitForPs2InterruptCount(reference: time_reference.Reference, expected: u32) bool {
    var attempts: usize = 0;
    while (ps2.count() < expected and attempts < 1_000) : (attempts += 1) {
        if (!reference.waitNanoseconds(100_000)) return false;
    }
    return ps2.count() == expected;
}

fn ioApicFailure(reason: []const u8) noreturn {
    debugWrite("IOAPIC initialization failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn startApplicationProcessors(
    info: *const boot.BootInfo,
    allocator: *memory.FrameAllocator,
    discovery: acpi.Discovery,
    local_apic: apic.Information,
    reference: time_reference.Reference,
    timer_ticks_per_second: u64,
) ?u8 {
    const madt = discovery.madt orelse smpFailure("validated ACPI did not contain a MADT");
    const report = smp.start(
        info,
        allocator,
        madt,
        local_apic,
        reference,
        timer_ticks_per_second,
    ) orelse
        smpFailure("trampoline patching, INIT/SIPI delivery, or AP acknowledgement failed");

    debugWrite("SMP startup: BSP APIC ");
    debugWriteU64Decimal(report.bsp_apic_id);
    debugWrite(", MADT processors ");
    debugWriteU64Decimal(report.madt_processor_count);
    debugWrite(", AP targets ");
    debugWriteUsizeDecimal(report.target_count);
    debugWrite(", discovered APs ");
    debugWriteUsizeDecimal(report.discovered_application_processors);
    debugWrite(", parked APs ");
    debugWriteUsizeDecimal(report.parked_application_processors);
    debugWrite(", trampoline 0x");
    debugWriteHex64(@intCast(report.trampoline_base));
    debugWrite(", SIPI vector 0x");
    debugWriteHex8(report.startup_vector);
    debugWrite("\r\n");

    for (report.processors[0..report.target_count]) |processor| {
        debugWrite("AP online: expected APIC ");
        debugWriteU64Decimal(processor.expected_apic_id);
        debugWrite(", actual APIC ");
        debugWriteU64Decimal(processor.actual_apic_id);
        debugWrite(", state ");
        debugWriteU64Decimal(processor.state);
        debugWrite(", stack 0x");
        debugWriteHex64(@intCast(processor.stack_base));
        debugWrite(" + ");
        debugWriteUsizeDecimal(processor.stack_size);
        debugWrite(" bytes\r\n");
        debugWrite("AP private descriptors: GDT 0x");
        debugWriteHex64(@intCast(processor.gdt_address));
        debugWrite(", TSS 0x");
        debugWriteHex64(@intCast(processor.tss_address));
        debugWrite(", IDT 0x");
        debugWriteHex64(@intCast(processor.idt_address));
        debugWrite(", CS 0x");
        debugWriteHex16(processor.active_cs);
        debugWrite(", TR 0x");
        debugWriteHex16(processor.active_tr);
        debugWrite(", checksum 0x");
        debugWriteHex64(processor.work_checksum);
        debugWrite("\r\n");
        debugWrite("AP mailbox complete: APIC ");
        debugWriteU64Decimal(processor.actual_apic_id);
        debugWrite(", epoch ");
        debugWriteU64Decimal(processor.completion_epoch);
        debugWrite(", input 0x");
        debugWriteHex64(processor.work_input);
        debugWrite(", result 0x");
        debugWriteHex64(processor.work_result);
        debugWrite("\r\n");
        debugWrite("AP run queue complete: APIC ");
        debugWriteU64Decimal(processor.actual_apic_id);
        debugWrite(", queued ");
        debugWriteU64Decimal(processor.run_queue_jobs);
        debugWrite(", completed ");
        debugWriteU64Decimal(processor.run_queue_completed);
        debugWrite(", last sequence ");
        debugWriteU64Decimal(processor.run_queue_last_sequence);
        debugWrite(", checksum 0x");
        debugWriteHex64(processor.run_queue_checksum);
        debugWrite("\r\n");
        debugWrite("AP synchronization worker: APIC ");
        debugWriteU64Decimal(processor.actual_apic_id);
        debugWrite(", worker ");
        debugWriteU64Decimal(processor.sync_worker_id);
        debugWrite(", acquisitions ");
        debugWriteU64Decimal(processor.sync_acquisitions);
        debugWrite(", barrier generation ");
        debugWriteU64Decimal(processor.sync_barrier_generation);
        debugWrite("\r\n");
        debugWrite("AP local tasks: APIC ");
        debugWriteU64Decimal(processor.actual_apic_id);
        debugWrite(", stacks 0x");
        debugWriteHex64(@intCast(processor.local_task_first_stack));
        debugWrite("/0x");
        debugWriteHex64(@intCast(processor.local_task_second_stack));
        debugWrite(", switches ");
        debugWriteU64Decimal(processor.local_task_context_switches);
        debugWrite(", yields ");
        debugWriteU64Decimal(processor.local_task_first_yields);
        debugWrite("/");
        debugWriteU64Decimal(processor.local_task_second_yields);
        debugWrite(", trace ");
        debugWrite(processor.local_task_trace[0..processor.local_task_trace_length]);
        debugWrite(if (processor.local_task_canaries_intact) ", canaries intact\r\n" else ", canary failure\r\n");
        debugWrite("AP tick scheduler: APIC ");
        debugWriteU64Decimal(processor.actual_apic_id);
        debugWrite(", jobs ");
        debugWriteU64Decimal(processor.scheduler_jobs);
        debugWrite(", ticks ");
        debugWriteU64Decimal(processor.scheduler_ticks);
        debugWrite(", dispatches ");
        debugWriteU64Decimal(processor.scheduler_dispatches);
        debugWrite(", halts ");
        debugWriteU64Decimal(processor.scheduler_halt_count);
        debugWrite(", checksum 0x");
        debugWriteHex64(processor.scheduler_checksum);
        debugWrite("\r\n");
        debugWrite("AP local timer: APIC ");
        debugWriteU64Decimal(processor.actual_apic_id);
        debugWrite(", vector 0x");
        debugWriteHex8(report.ap_timer_vector);
        debugWrite(", count ");
        debugWriteU64Decimal(processor.timer_initial_count);
        debugWrite(", interrupts ");
        debugWriteU64Decimal(processor.timer_interrupt_count);
        debugWrite(", epoch ");
        debugWriteU64Decimal(processor.timer_armed_epoch);
        debugWrite(", halts ");
        debugWriteU64Decimal(processor.timer_halt_count);
        debugWrite("\r\n");
        debugWrite("AP targeted IPI: APIC ");
        debugWriteU64Decimal(processor.actual_apic_id);
        debugWrite(", vector 0x");
        debugWriteHex8(report.ipi_wake_vector);
        debugWrite(", wake ");
        debugWriteU64Decimal(processor.ipi_wake_count);
        debugWrite(", halts ");
        debugWriteU64Decimal(processor.idle_halt_count);
        debugWrite(", checksum 0x");
        debugWriteHex64(processor.ipi_job_checksum);
        debugWrite("\r\n");
        if (processor.stolen_jobs_executed != 0) {
            debugWrite("AP work stealing: APIC ");
            debugWriteU64Decimal(processor.actual_apic_id);
            debugWrite(" executed ");
            debugWriteU64Decimal(processor.stolen_jobs_executed);
            debugWrite(" stolen jobs\r\n");
        }
    }

    if (report.target_count == 3) {
        debugWrite("Work stealing complete: source APIC ");
        debugWriteU64Decimal(report.work_stealing_source_apic);
        debugWrite(", jobs ");
        debugWriteU64Decimal(report.work_stealing_jobs);
        debugWrite(", owner ");
        debugWriteU64Decimal(report.work_stealing_owner_jobs);
        debugWrite(", stolen ");
        debugWriteU64Decimal(report.work_stealing_stolen_jobs);
        debugWrite(", checksum 0x");
        debugWriteHex64(report.work_stealing_checksum);
        debugWrite("\r\n");
    } else {
        debugWrite("Work stealing skipped: requires three selected application processors\r\n");
    }

    if (report.online_count != report.target_count) {
        smpFailure("not every selected application processor reached long mode");
    }
    const legacy_irq_target = selectLegacyIrqTarget(&report);
    if (report.target_count == 0) {
        debugWrite("SMP validation skipped: uniprocessor topology; BSP APIC ");
        debugWriteU64Decimal(report.bsp_apic_id);
        debugWrite(" remains the only active processor\r\n");
        debugWrite("SMP startup complete: 0/0 selected application processors online; ");
        debugWriteUsizeDecimal(report.parked_application_processors);
        debugWrite(" additional application processors left parked\r\n");
        return legacy_irq_target;
    }

    debugWrite("SMP synchronization complete: ");
    debugWriteU64Decimal(report.sync_participants);
    debugWrite(" participants, ");
    debugWriteU64Decimal(report.sync_total_increments);
    debugWrite(" locked increments, tickets ");
    debugWriteU64Decimal(report.sync_lock_serving);
    debugWrite("/");
    debugWriteU64Decimal(report.sync_lock_next);
    debugWrite(", barrier generation ");
    debugWriteU64Decimal(report.sync_barrier_generation);
    debugWrite(", checksum 0x");
    debugWriteHex64(report.sync_checksum);
    debugWrite("\r\n");
    debugWrite("Per-AP task contexts complete: ");
    debugWriteU64Decimal(report.ap_task_completed);
    debugWrite("/");
    debugWriteU64Decimal(report.ap_task_targets);
    debugWrite(" APs, total context switches ");
    debugWriteU64Decimal(report.ap_task_context_switches);
    debugWrite(", trace ABABABABABBB on every core\r\n");
    debugWrite("Per-AP tick schedulers complete: jobs ");
    debugWriteU64Decimal(report.ap_scheduler_jobs_per_core);
    debugWrite("/core, quantum count ");
    debugWriteU64Decimal(report.ap_scheduler_quantum_count);
    debugWrite(", ");
    debugWriteU64Decimal(report.ap_scheduler_completed);
    debugWrite("/");
    debugWriteU64Decimal(report.ap_scheduler_targets);
    debugWrite(" APs dispatched exactly one job per timer tick\r\n");
    debugWrite("Per-AP timers complete: vector 0x");
    debugWriteHex8(report.ap_timer_vector);
    debugWrite(", count ");
    debugWriteU64Decimal(report.ap_timer_initial_count);
    debugWrite(", ");
    debugWriteU64Decimal(report.ap_timer_completed);
    debugWrite("/");
    debugWriteU64Decimal(report.ap_timer_targets);
    debugWrite(" APs woke autonomously from local timer interrupts\r\n");
    debugWrite("Targeted AP wakeups complete: vector 0x");
    debugWriteHex8(report.ipi_wake_vector);
    debugWrite(", ");
    debugWriteU64Decimal(report.ipi_wake_completed);
    debugWrite("/");
    debugWriteU64Decimal(report.ipi_wake_targets);
    debugWrite(" APs woke from HLT and acknowledged EOI\r\n");
    debugWrite("SMP startup complete: ");
    debugWriteUsizeDecimal(report.online_count);
    debugWrite("/");
    debugWriteUsizeDecimal(report.target_count);
    debugWrite(" selected application processors online; ");
    debugWriteUsizeDecimal(report.parked_application_processors);
    debugWrite(" additional application processors left parked\r\n");
    return legacy_irq_target;
}

fn selectLegacyIrqTarget(report: *const smp.Report) ?u8 {
    for (report.processors[0..report.target_count]) |processor| {
        if (processor.online and processor.actual_apic_id <= 0xFF) {
            return @intCast(processor.actual_apic_id);
        }
    }
    if (report.bsp_apic_id <= 0xFF) return @intCast(report.bsp_apic_id);
    return null;
}

fn smpFailure(reason: []const u8) noreturn {
    debugWrite("SMP startup failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn enumeratePci(discovery: acpi.Discovery) pci.Inventory {
    const inventory = if (discovery.mcfg_address) |mcfg_address|
        pci.enumerate(mcfg_address) orelse pci.enumerateLegacy() orelse
            pciFailure("MCFG/ECAM and legacy PCI configuration both failed")
    else
        pci.enumerateLegacy() orelse
            pciFailure("ACPI omitted MCFG and legacy PCI configuration mechanism #1 was unavailable");

    switch (inventory.access_method) {
        .ecam => {
            debugWrite("PCIe ECAM active: MCFG 0x");
            debugWriteHex64(@intCast(inventory.mcfg_address.?));
            debugWrite(", allocations ");
            debugWriteUsizeDecimal(inventory.allocation_count);
            debugWrite(", buses scanned ");
            debugWriteUsizeDecimal(inventory.scanned_bus_count);
            debugWrite("\r\n");
        },
        .legacy_io => {
            debugWrite("Legacy PCI configuration active: mechanism #1 ports 0x0CF8/0x0CFC, buses scanned ");
            debugWriteUsizeDecimal(inventory.scanned_bus_count);
            debugWrite("\r\n");
        },
    }
    debugWrite("PCI inventory: ");
    debugWriteUsizeDecimal(inventory.function_count);
    debugWrite(" functions, ");
    debugWriteUsizeDecimal(inventory.bridge_count);
    debugWrite(" PCI bridges, retained ");
    debugWriteUsizeDecimal(inventory.retained_count);
    debugWrite("\r\n");

    const print_count = @min(inventory.retained_count, 16);
    var index: usize = 0;
    while (index < print_count) : (index += 1) {
        const function = inventory.functions[index];
        debugWrite("PCI function ");
        debugWriteHex16(function.segment);
        debugWrite(":");
        debugWriteHex8(function.bus);
        debugWrite(":");
        debugWriteHex8(function.device);
        debugWrite(".");
        debugWriteU64Decimal(function.function);
        debugWrite(" vendor 0x");
        debugWriteHex16(function.vendor_id);
        debugWrite(" device 0x");
        debugWriteHex16(function.device_id);
        debugWrite(" class ");
        debugWriteHex8(function.class_code);
        debugWrite(":");
        debugWriteHex8(function.subclass);
        debugWrite(":");
        debugWriteHex8(function.programming_interface);
        debugWrite(" header 0x");
        debugWriteHex8(function.header_type);
        debugWrite("\r\n");
    }
    return inventory;
}

fn pciFailure(reason: []const u8) noreturn {
    debugWrite("PCI discovery failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn initializeKernelHeap(allocator: *memory.FrameAllocator) void {
    const heap_pages: usize = 256;
    const region_base = allocator.allocateContiguousBelow(heap_pages, memory.four_gib) orelse
        heapFailure("unable to allocate a contiguous 1 MiB heap region");
    const region_size = heap_pages * @as(usize, @intCast(memory.page_size));
    kernel_heap = heap.Heap.init(region_base, region_size) orelse
        heapFailure("free-list heap rejected its physical region");
    kernel_heap_ready = true;

    const small = kernel_heap.allocate(24, 8) orelse heapFailure("24-byte allocation failed");
    const page = kernel_heap.allocate(4096, 64) orelse heapFailure("4096-byte allocation failed");
    const aligned = kernel_heap.allocate(73, 32) orelse heapFailure("73-byte allocation failed");

    if ((@intFromPtr(small.ptr) & 7) != 0 or
        (@intFromPtr(page.ptr) & 63) != 0 or
        (@intFromPtr(aligned.ptr) & 31) != 0)
    {
        heapFailure("allocation alignment contract failed");
    }
    if (slicesOverlap(small, page) or slicesOverlap(small, aligned) or slicesOverlap(page, aligned)) {
        heapFailure("heap returned overlapping allocations");
    }

    @memset(small, 0xA5);
    @memset(page, 0x5A);
    @memset(aligned, 0x3C);
    if (small[0] != 0xA5 or small[small.len - 1] != 0xA5 or
        page[0] != 0x5A or page[page.len - 1] != 0x5A or
        aligned[0] != 0x3C or aligned[aligned.len - 1] != 0x3C)
    {
        heapFailure("heap payload write/read verification failed");
    }
    if (!kernel_heap.validate()) heapFailure("free-list invariants failed after allocation");

    if (!kernel_heap.free(page)) heapFailure("freeing page allocation failed");
    if (!kernel_heap.free(small)) heapFailure("freeing small allocation failed");
    if (!kernel_heap.free(aligned)) heapFailure("freeing aligned allocation failed");
    if (!kernel_heap.validate()) heapFailure("free-list coalescing validation failed");

    const after_coalesce = kernel_heap.statistics();
    if (after_coalesce.free_bytes != after_coalesce.region_size or
        after_coalesce.allocated_bytes != 0 or
        after_coalesce.active_allocations != 0)
    {
        heapFailure("heap did not coalesce back into one fully free region");
    }

    const large = kernel_heap.allocate(region_size / 2, 4096) orelse
        heapFailure("coalesced half-region allocation failed");
    @memset(large, 0xC3);
    if (large[0] != 0xC3 or large[large.len - 1] != 0xC3) {
        heapFailure("large allocation verification failed");
    }
    if (!kernel_heap.free(large) or !kernel_heap.validate()) {
        heapFailure("large allocation release failed");
    }

    const statistics = kernel_heap.statistics();
    debugWrite("Kernel heap active: base 0x");
    debugWriteHex64(@intCast(statistics.region_base));
    debugWrite(", size ");
    debugWriteUsizeDecimal(statistics.region_size);
    debugWrite(" bytes\r\n");
    debugWrite("Heap allocator verified: aligned alloc/free, split, coalesce; ");
    debugWriteUsizeDecimal(statistics.total_allocations);
    debugWrite(" allocations and ");
    debugWriteUsizeDecimal(statistics.total_frees);
    debugWrite(" frees\r\n");
}

fn slicesOverlap(first: []const u8, second: []const u8) bool {
    const first_start = @intFromPtr(first.ptr);
    const second_start = @intFromPtr(second.ptr);
    return first_start < second_start + second.len and second_start < first_start + first.len;
}

fn heapFailure(reason: []const u8) noreturn {
    debugWrite("Kernel heap failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn initializeSerial() void {
    if (!serial.initialize()) serialFailure("COM1 loopback self-test failed");
    if (!serial.write("ZigOs COM1 serial diagnostics online\r\n")) {
        serialFailure("COM1 transmitter did not become ready");
    }

    debugWrite("COM1 serial diagnostics active at I/O port 0x");
    debugWriteHex16(serial.basePort());
    debugWrite(" (115200 8N1, FIFO enabled)\r\n");
}

fn serialFailure(reason: []const u8) noreturn {
    debugWrite("Serial initialization failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn inspectE1000e(
    inventory: pci.Inventory,
    allocator: *memory.FrameAllocator,
    interrupt_target: ?u8,
) bool {
    var network_function: ?pci.Function = null;
    for (inventory.functions[0..inventory.retained_count]) |function| {
        if (function.vendor_id == 0x8086 and function.device_id == 0x10D3 and
            function.class_code == 0x02 and function.subclass == 0x00)
        {
            network_function = function;
            break;
        }
    }

    const function = network_function orelse {
        debugWrite("Intel 82574L network controller not present; continuing without networking\r\n");
        return false;
    };
    const capabilities = pci.inspectCapabilities(function) orelse
        networkFailure("PCI capability list was malformed");
    debugWrite("e1000e PCI capabilities: count ");
    debugWriteU64Decimal(capabilities.count);
    debugWrite(", MSI ");
    if (capabilities.msi_offset) |offset| {
        debugWrite("+0x");
        debugWriteHex8(offset);
    } else {
        debugWrite("absent");
    }
    debugWrite(", MSI-X ");
    if (capabilities.msix_offset) |offset| {
        debugWrite("+0x");
        debugWriteHex8(offset);
    } else {
        debugWrite("absent");
    }
    debugWrite("\r\n");

    if (pci.inspectMsi(function)) |msi| {
        debugWrite("e1000e MSI descriptor: ");
        debugWrite(if (msi.address_64_bit) "64" else "32");
        debugWrite("-bit address, messages capable ");
        debugWriteU64Decimal(@as(u64, 1) << msi.multiple_message_capable);
        debugWrite(", per-vector mask ");
        debugWrite(if (msi.per_vector_masking) "yes" else "no");
        debugWrite("\r\n");
    }
    if (pci.inspectMsix(function)) |msix| {
        debugWrite("e1000e MSI-X descriptor: vectors ");
        debugWriteU64Decimal(msix.table_size);
        debugWrite(", table BAR ");
        debugWriteU64Decimal(msix.table_bar_index);
        debugWrite(" +0x");
        debugWriteHex64(msix.table_offset);
        debugWrite(", PBA BAR ");
        debugWriteU64Decimal(msix.pending_bar_index);
        debugWrite(" +0x");
        debugWriteHex64(msix.pending_offset);
        debugWrite("\r\n");
    }

    var controller = e1000e.inspect(function, allocator) orelse
        networkFailure("PCI command, BAR mapping, MAC, or status registers were invalid");
    debugWrite("e1000e controller discovered at ");
    debugWriteHex16(function.segment);
    debugWrite(":");
    debugWriteHex8(function.bus);
    debugWrite(":");
    debugWriteHex8(function.device);
    debugWrite(".");
    debugWriteU64Decimal(function.function);
    debugWrite(", vendor 0x");
    debugWriteHex16(function.vendor_id);
    debugWrite(", device 0x");
    debugWriteHex16(function.device_id);
    debugWrite(", BAR0 0x");
    debugWriteHex64(controller.bar0);
    debugWrite(", identity map 0x");
    debugWriteHex64(controller.mapped_base);
    debugWrite(" + ");
    debugWriteU64Decimal(controller.mapped_bytes);
    debugWrite(" bytes using ");
    debugWriteU64Decimal(controller.mapping_table_pages);
    debugWrite(" new table page(s)\r\n");

    debugWrite("e1000e MAC ");
    for (controller.mac_address, 0..) |octet, index| {
        if (index != 0) debugWrite(":");
        debugWriteHex8(octet);
    }
    debugWrite(", link ");
    debugWrite(if (controller.link_up) "up" else "down");
    debugWrite(", speed ");
    debugWriteU64Decimal(controller.link_speed_mbps);
    debugWrite(" Mb/s, CTRL 0x");
    debugWriteHex64(controller.control);
    debugWrite(", STATUS 0x");
    debugWriteHex64(controller.status);
    debugWrite(", CTRL_EXT 0x");
    debugWriteHex64(controller.control_extended);
    debugWrite("\r\n");

    const target_apic_id = interrupt_target orelse
        networkFailure("no routable online CPU was available for MSI-X");
    const network = e1000e.initializeAndTestNetwork(
        &controller,
        allocator,
        target_apic_id,
    ) orelse networkFailure("reset, DMA rings, MSI-X, ARP, or ICMP validation failed");

    debugWrite("e1000e rings active: RX 0x");
    debugWriteHex64(network.rx_ring_address);
    debugWrite(", TX 0x");
    debugWriteHex64(network.tx_ring_address);
    debugWrite(", descriptors ");
    debugWriteU64Decimal(network.descriptor_count);
    debugWrite(", TX buffer 0x");
    debugWriteHex64(network.tx_buffer_address);
    debugWrite(", RX buffer 0x");
    debugWriteHex64(network.rx_buffer_address);
    debugWrite("\r\n");

    debugWrite("e1000e MSI-X active: capability +0x");
    debugWriteHex8(network.msix_capability_offset);
    debugWrite(", table entry 0 at 0x");
    debugWriteHex64(network.msix_table_address);
    debugWrite(", vectors ");
    debugWriteU64Decimal(network.msix_vector_count);
    debugWrite(", vector 0x");
    debugWriteHex8(e1000e.interrupt_vector);
    debugWrite(", target APIC ");
    debugWriteU64Decimal(network.interrupt_target_apic_id);
    debugWrite(", control 0x");
    debugWriteHex16(network.msix_control);
    debugWrite(", mapping pages ");
    debugWriteU64Decimal(network.msix_mapping_table_pages);
    debugWrite("\r\n");

    debugWrite("e1000e ARP request transmitted: 10.0.2.15 -> 10.0.2.2, ");
    debugWriteU64Decimal(network.transmitted_length);
    debugWrite(" bytes, TX interrupts ");
    debugWriteU64Decimal(network.tx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.tx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e ARP reply received: gateway MAC ");
    for (network.gateway_mac_address, 0..) |octet, index| {
        if (index != 0) debugWrite(":");
        debugWriteHex8(octet);
    }
    debugWrite(", opcode ");
    debugWriteU64Decimal(network.arp_opcode);
    debugWrite(", sender ");
    debugWriteIpv4(network.sender_ipv4);
    debugWrite(", target ");
    debugWriteIpv4(network.target_ipv4);
    debugWrite(", ");
    debugWriteU64Decimal(network.received_length);
    debugWrite(" bytes, RX interrupts ");
    debugWriteU64Decimal(network.rx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.rx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e ICMP echo request transmitted: 10.0.2.15 -> 10.0.2.2, ");
    debugWriteU64Decimal(network.icmp_transmitted_length);
    debugWrite(" bytes, identifier 0x");
    debugWriteHex16(network.icmp_identifier);
    debugWrite(", sequence ");
    debugWriteU64Decimal(network.icmp_sequence);
    debugWrite(", TX interrupts ");
    debugWriteU64Decimal(network.icmp_tx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.icmp_tx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e ICMP echo reply received: 10.0.2.2 -> 10.0.2.15, ");
    debugWriteU64Decimal(network.icmp_received_length);
    debugWrite(" bytes, TTL ");
    debugWriteU64Decimal(network.icmp_reply_ttl);
    debugWrite(", payload ");
    debugWriteU64Decimal(network.icmp_payload_length);
    debugWrite(" bytes, RX interrupts ");
    debugWriteU64Decimal(network.icmp_rx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.icmp_rx_interrupt_cause);
    debugWrite("\r\n");
    return true;
}

fn networkFailure(reason: []const u8) noreturn {
    debugWrite("Network discovery failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn inspectXhci(
    inventory: pci.Inventory,
    allocator: *memory.FrameAllocator,
    graphical_console: ?*framebuffer_console.Console,
    interrupt_target: ?u8,
) bool {
    var controller_function: ?pci.Function = null;
    for (inventory.functions[0..inventory.retained_count]) |function| {
        if (function.class_code == 0x0C and
            function.subclass == 0x03 and
            function.programming_interface == 0x30)
        {
            controller_function = function;
            break;
        }
    }
    const function = controller_function orelse {
        debugWrite("xHCI controller not present; continuing without USB input\r\n");
        return false;
    };
    const pci_capabilities = pci.inspectCapabilities(function) orelse {
        debugWrite("xHCI PCI capability list was malformed; continuing without USB input\r\n");
        return false;
    };
    debugWrite("xHCI PCI capabilities: count ");
    debugWriteU64Decimal(pci_capabilities.count);
    debugWrite(", MSI ");
    if (pci_capabilities.msi_offset) |offset| {
        debugWrite("+0x");
        debugWriteHex8(offset);
    } else {
        debugWrite("absent");
    }
    debugWrite(", MSI-X ");
    if (pci_capabilities.msix_offset) |offset| {
        debugWrite("+0x");
        debugWriteHex8(offset);
    } else {
        debugWrite("absent");
    }
    debugWrite("\r\n");
    if (pci_capabilities.msix_offset != null) {
        const msix = pci.inspectMsix(function) orelse {
            debugWrite("xHCI MSI-X capability was malformed; continuing without USB input\r\n");
            return false;
        };
        debugWrite("xHCI MSI-X descriptor: vectors ");
        debugWriteU64Decimal(msix.table_size);
        debugWrite(", table BAR ");
        debugWriteU64Decimal(msix.table_bar_index);
        debugWrite(" +0x");
        debugWriteHex64(msix.table_offset);
        debugWrite(", PBA BAR ");
        debugWriteU64Decimal(msix.pending_bar_index);
        debugWrite(" +0x");
        debugWriteHex64(msix.pending_offset);
        debugWrite("\r\n");
    }
    const controller = xhci.inspect(function, allocator) orelse {
        debugWrite("xHCI controller registers were unusable; continuing without USB input\r\n");
        return false;
    };

    debugWrite("xHCI controller discovered at ");
    debugWriteHex16(function.segment);
    debugWrite(":");
    debugWriteHex8(function.bus);
    debugWrite(":");
    debugWriteHex8(function.device);
    debugWrite(".");
    debugWriteU64Decimal(function.function);
    debugWrite(", vendor 0x");
    debugWriteHex16(function.vendor_id);
    debugWrite(", device 0x");
    debugWriteHex16(function.device_id);
    debugWrite(", MMIO 0x");
    debugWriteHex64(@intCast(controller.base_address));
    debugWrite(", sparse identity map 0x");
    debugWriteHex64(controller.mapping_base);
    debugWrite(" + ");
    debugWriteU64Decimal(controller.mapping_bytes);
    debugWrite(" bytes using ");
    debugWriteU64Decimal(controller.mapping_table_pages);
    debugWrite(" new table page(s)\r\n");
    debugWrite("xHCI capabilities: version ");
    debugWriteU64Decimal(controller.hci_version >> 8);
    debugWrite(".");
    debugWriteHex8(@truncate(controller.hci_version));
    debugWrite(", ");
    debugWriteU64Decimal(controller.maximum_slots);
    debugWrite(" slots, ");
    debugWriteU64Decimal(controller.maximum_interrupters);
    debugWrite(" interrupters, ");
    debugWriteU64Decimal(controller.maximum_ports);
    debugWrite(" ports, ");
    debugWrite(if (controller.supports_64_bit_addressing) "64-bit addressing" else "32-bit addressing");
    debugWrite(if (controller.context_size_64_bytes) ", 64-byte contexts" else ", 32-byte contexts");
    debugWrite(", doorbells +0x");
    debugWriteHex64(controller.doorbell_offset);
    debugWrite(", runtime +0x");
    debugWriteHex64(controller.runtime_offset);
    debugWrite("\r\n");

    for (controller.ports[0..controller.retained_port_count]) |port| {
        debugWrite("xHCI port ");
        debugWriteU64Decimal(port.number);
        debugWrite(": ");
        debugWrite(if (port.connected) "connected" else "disconnected");
        debugWrite(if (port.enabled) ", enabled" else ", disabled");
        debugWrite(if (port.powered) ", powered" else ", unpowered");
        debugWrite(", speed ID ");
        debugWriteU64Decimal(port.speed_id);
        debugWrite(", PORTSC 0x");
        debugWriteHex64(port.port_status_control);
        debugWrite("\r\n");
    }
    debugWrite("USB keyboard attachment visible: ");
    debugWriteU64Decimal(controller.connected_port_count);
    debugWrite(" connected xHCI port(s); read-only discovery complete\r\n");
    if (controller.connected_port_count == 0) {
        debugWrite("USB keyboard unavailable; continuing without interactive shell\r\n");
        return false;
    }
    const console = graphical_console orelse {
        debugWrite("Framebuffer console unavailable; continuing without interactive USB shell\r\n");
        return false;
    };

    var ownership = xhci.takeOwnership(controller, allocator, interrupt_target) orelse
        xhciFailure("controller reset, MSI-X setup, ring installation, or Enable Slot completion failed");
    debugWrite("xHCI ownership active: DCBAA 0x");
    debugWriteHex64(@intCast(ownership.dcbaa_address));
    debugWrite(", command ring 0x");
    debugWriteHex64(@intCast(ownership.command_ring_address));
    debugWrite(", event ring 0x");
    debugWriteHex64(@intCast(ownership.event_ring_address));
    debugWrite(", ERST 0x");
    debugWriteHex64(@intCast(ownership.erst_address));
    debugWrite(", page size ");
    debugWriteU64Decimal(ownership.page_size);
    debugWrite(", scratchpads ");
    debugWriteU64Decimal(ownership.scratchpad_count);
    debugWrite(", slots ");
    debugWriteU64Decimal(ownership.enabled_slots);
    debugWrite("\r\n");
    debugWrite("xHCI command completed: Enable Slot, completion ");
    debugWriteU64Decimal(ownership.completion_code);
    debugWrite(", slot ");
    debugWriteU64Decimal(ownership.slot_id);
    debugWrite(", command pointer 0x");
    debugWriteHex64(ownership.command_pointer);
    debugWrite(", event cycle ");
    debugWriteU64Decimal(ownership.event_cycle);
    debugWrite(if (ownership.controller_running) ", controller running" else ", controller halted");
    debugWrite(if (ownership.legacy_handoff_performed) ", legacy handoff claimed\r\n" else ", no legacy handoff required\r\n");
    if (ownership.interrupts_enabled) {
        if (ownership.enable_slot_interrupt_count != 1) {
            xhciFailure("Enable Slot did not complete through exactly one xHCI MSI-X interrupt");
        }
        debugWrite("xHCI MSI-X active: capability +0x");
        debugWriteHex8(ownership.msix_capability_offset);
        debugWrite(", table entry 0 at 0x");
        debugWriteHex64(@intCast(ownership.msix_table_address));
        debugWrite(", vectors ");
        debugWriteU64Decimal(ownership.msix_vector_count);
        debugWrite(", vector 0x");
        debugWriteHex8(ownership.interrupt_vector);
        debugWrite(", target APIC ");
        debugWriteU64Decimal(ownership.interrupt_target_apic_id);
        debugWrite(", control 0x");
        debugWriteHex16(ownership.msix_control);
        debugWrite(", mapping pages ");
        debugWriteU64Decimal(ownership.msix_mapping_table_pages);
        debugWrite("\r\n");
        debugWrite("xHCI Enable Slot MSI-X completion verified: interrupt count ");
        debugWriteU64Decimal(ownership.enable_slot_interrupt_count);
        debugWrite(", USBSTS 0x");
        debugWriteHex64(ownership.enable_slot_usbsts);
        debugWrite(", IMAN 0x");
        debugWriteHex64(ownership.enable_slot_iman);
        debugWrite("\r\n");
    } else {
        debugWrite("xHCI MSI-X unavailable; bounded event-ring polling retained\r\n");
    }
    const addressed = xhci.addressConnectedDevice(controller, &ownership, allocator) orelse {
        const diagnostic = xhci.address_diagnostics;
        debugWrite("xHCI Address Device failure: stage ");
        debugWrite(xhci.addressStageName(diagnostic.stage));
        debugWrite(", port ");
        debugWriteU64Decimal(diagnostic.port_number);
        debugWrite(", PORTSC 0x");
        debugWriteHex64(diagnostic.port_status);
        debugWrite(", event type ");
        debugWriteU64Decimal(diagnostic.event_type);
        debugWrite(", completion ");
        debugWriteU64Decimal(diagnostic.completion_code);
        debugWrite(", event slot ");
        debugWriteU64Decimal(diagnostic.event_slot_id);
        debugWrite(", command pointer 0x");
        debugWriteHex64(diagnostic.command_pointer);
        debugWrite(", USB address ");
        debugWriteU64Decimal(diagnostic.device_address);
        debugWrite(", slot state ");
        debugWriteU64Decimal(diagnostic.slot_state);
        debugWrite(", EP0 state ");
        debugWriteU64Decimal(diagnostic.endpoint0_state);
        debugWrite("\r\n");
        xhciFailure("port reset, device-context construction, or Address Device completion failed");
    };
    debugWrite("xHCI port reset complete: port ");
    debugWriteU64Decimal(addressed.port_number);
    debugWrite(", speed ID ");
    debugWriteU64Decimal(addressed.port_speed_id);
    debugWrite(", PORTSC 0x");
    debugWriteHex64(addressed.reset_port_status);
    debugWrite(", EP0 max packet ");
    debugWriteU64Decimal(addressed.endpoint0_max_packet_size);
    debugWrite(", skipped ");
    debugWriteU64Decimal(addressed.skipped_port_status_events);
    debugWrite(" port-status event(s)\r\n");
    debugWrite("xHCI Address Device completed: slot ");
    debugWriteU64Decimal(addressed.slot_id);
    debugWrite(", USB address ");
    debugWriteU64Decimal(addressed.device_address);
    debugWrite(", slot state ");
    debugWriteU64Decimal(addressed.slot_state);
    debugWrite(", EP0 state ");
    debugWriteU64Decimal(addressed.endpoint0_state);
    debugWrite(", completion ");
    debugWriteU64Decimal(addressed.completion_code);
    debugWrite(", context size ");
    debugWriteU64Decimal(addressed.context_size);
    debugWrite(", device context 0x");
    debugWriteHex64(@intCast(addressed.device_context_address));
    debugWrite(", input context 0x");
    debugWriteHex64(@intCast(addressed.input_context_address));
    debugWrite(", EP0 ring 0x");
    debugWriteHex64(@intCast(addressed.transfer_ring_address));
    debugWrite("\r\n");
    var mutable_addressed = addressed;
    const descriptor = xhci.readDeviceDescriptor(
        controller,
        &ownership,
        &mutable_addressed,
        allocator,
    ) orelse xhciFailure("EP0 GET_DESCRIPTOR transfer or device-descriptor validation failed");
    debugWrite("USB device descriptor read: length ");
    debugWriteU64Decimal(descriptor.length);
    debugWrite(", type ");
    debugWriteU64Decimal(descriptor.descriptor_type);
    debugWrite(", USB BCD 0x");
    debugWriteHex16(descriptor.usb_version_bcd);
    debugWrite(", class 0x");
    debugWriteHex8(descriptor.device_class);
    debugWrite(":0x");
    debugWriteHex8(descriptor.device_subclass);
    debugWrite(":0x");
    debugWriteHex8(descriptor.device_protocol);
    debugWrite(", EP0 packet ");
    debugWriteU64Decimal(descriptor.endpoint0_max_packet_size);
    debugWrite("\r\n");
    debugWrite("USB identity: vendor 0x");
    debugWriteHex16(descriptor.vendor_id);
    debugWrite(", product 0x");
    debugWriteHex16(descriptor.product_id);
    debugWrite(", device BCD 0x");
    debugWriteHex16(descriptor.device_version_bcd);
    debugWrite(", configurations ");
    debugWriteU64Decimal(descriptor.configuration_count);
    debugWrite(", string indexes ");
    debugWriteU64Decimal(descriptor.manufacturer_string_index);
    debugWrite("/");
    debugWriteU64Decimal(descriptor.product_string_index);
    debugWrite("/");
    debugWriteU64Decimal(descriptor.serial_string_index);
    debugWrite("\r\n");
    debugWrite("xHCI EP0 transfer completed: completion ");
    debugWriteU64Decimal(descriptor.completion_code);
    debugWrite(", endpoint ");
    debugWriteU64Decimal(descriptor.endpoint_id);
    debugWrite(", slot ");
    debugWriteU64Decimal(descriptor.slot_id);
    debugWrite(", residual ");
    debugWriteU64Decimal(descriptor.transfer_residual);
    debugWrite(", event TRB 0x");
    debugWriteHex64(descriptor.event_trb_pointer);
    debugWrite(", buffer 0x");
    debugWriteHex64(@intCast(descriptor.buffer_address));
    debugWrite("\r\n");
    const configuration = xhci.readHidConfiguration(
        controller,
        &ownership,
        &mutable_addressed,
        allocator,
    ) orelse xhciFailure("configuration/HID descriptor transfer or parser failed");
    debugWrite("USB configuration descriptor: total ");
    debugWriteU64Decimal(configuration.total_length);
    debugWrite(" bytes, value ");
    debugWriteU64Decimal(configuration.configuration_value);
    debugWrite(", interfaces ");
    debugWriteU64Decimal(configuration.interface_count);
    debugWrite(", attributes 0x");
    debugWriteHex8(configuration.attributes);
    debugWrite(", max power ");
    debugWriteU64Decimal(configuration.maximum_power_ma);
    debugWrite(" mA\r\n");
    if (configuration.interface_protocol != 1) {
        debugWrite("USB HID boot interface is not a keyboard: class ");
        debugWriteU64Decimal(configuration.interface_class);
        debugWrite("/");
        debugWriteU64Decimal(configuration.interface_subclass);
        debugWrite("/");
        debugWriteU64Decimal(configuration.interface_protocol);
        debugWrite(", interface ");
        debugWriteU64Decimal(configuration.interface_number);
        debugWrite(", endpoint 0x");
        debugWriteHex8(configuration.endpoint_address);
        debugWrite("; continuing without interactive shell\r\n");
        return false;
    }
    debugWrite("HID boot keyboard interface: number ");
    debugWriteU64Decimal(configuration.interface_number);
    debugWrite(", alternate ");
    debugWriteU64Decimal(configuration.alternate_setting);
    debugWrite(", endpoints ");
    debugWriteU64Decimal(configuration.endpoint_count);
    debugWrite(", class ");
    debugWriteU64Decimal(configuration.interface_class);
    debugWrite("/");
    debugWriteU64Decimal(configuration.interface_subclass);
    debugWrite("/");
    debugWriteU64Decimal(configuration.interface_protocol);
    debugWrite(", HID BCD 0x");
    debugWriteHex16(configuration.hid_version_bcd);
    debugWrite(", report type 0x");
    debugWriteHex8(configuration.report_descriptor_type);
    debugWrite(", report length ");
    debugWriteU64Decimal(configuration.report_descriptor_length);
    debugWrite("\r\n");
    debugWrite("HID interrupt endpoint: address 0x");
    debugWriteHex8(configuration.endpoint_address);
    debugWrite(", attributes 0x");
    debugWriteHex8(configuration.endpoint_attributes);
    debugWrite(", max packet ");
    debugWriteU64Decimal(configuration.endpoint_max_packet_size);
    debugWrite(", interval ");
    debugWriteU64Decimal(configuration.endpoint_interval);
    debugWrite(", completion ");
    debugWriteU64Decimal(configuration.completion_code);
    debugWrite(", residual ");
    debugWriteU64Decimal(configuration.transfer_residual);
    debugWrite("\r\n");
    const hid_endpoint = xhci.configureHidEndpoint(
        controller,
        &ownership,
        &mutable_addressed,
        configuration,
        allocator,
    ) orelse xhciFailure("SET_CONFIGURATION or Configure Endpoint failed");
    debugWrite("USB SET_CONFIGURATION completed: value ");
    debugWriteU64Decimal(hid_endpoint.configuration_value);
    debugWrite(", completion ");
    debugWriteU64Decimal(hid_endpoint.set_configuration_completion);
    debugWrite("\r\n");
    debugWrite("xHCI HID endpoint configured: address 0x");
    debugWriteHex8(hid_endpoint.endpoint_address);
    debugWrite(", DCI ");
    debugWriteU64Decimal(hid_endpoint.endpoint_id);
    debugWrite(", type ");
    debugWriteU64Decimal(hid_endpoint.endpoint_type);
    debugWrite(", interval ");
    debugWriteU64Decimal(hid_endpoint.interval);
    debugWrite(", max packet ");
    debugWriteU64Decimal(hid_endpoint.max_packet_size);
    debugWrite(", max burst ");
    debugWriteU64Decimal(hid_endpoint.max_burst_size);
    debugWrite(", max ESIT ");
    debugWriteU64Decimal(hid_endpoint.max_esit_payload);
    debugWrite("\r\n");
    debugWrite("xHCI Configure Endpoint completed: completion ");
    debugWriteU64Decimal(hid_endpoint.configure_completion);
    debugWrite(", endpoint state ");
    debugWriteU64Decimal(hid_endpoint.endpoint_state);
    debugWrite(", slot context entries ");
    debugWriteU64Decimal(hid_endpoint.slot_context_entries);
    debugWrite(", input context 0x");
    debugWriteHex64(@intCast(hid_endpoint.input_context_address));
    debugWrite(", interrupt ring 0x");
    debugWriteHex64(@intCast(hid_endpoint.transfer_ring_address));
    debugWrite("\r\n");
    var mutable_hid_endpoint = hid_endpoint;
    const input_arm = xhci.armHidKeyboardInput(
        controller,
        &ownership,
        &mutable_addressed,
        configuration,
        &mutable_hid_endpoint,
        allocator,
    ) orelse xhciFailure("HID SET_PROTOCOL/SET_IDLE or interrupt-IN arm failed");
    debugWrite("HID boot protocol ready: SET_PROTOCOL completion ");
    debugWriteU64Decimal(input_arm.protocol_completion);
    debugWrite(", SET_IDLE completion ");
    debugWriteU64Decimal(input_arm.idle_completion);
    debugWrite("\r\n");
    debugWrite("HID input transfer armed: slot ");
    debugWriteU64Decimal(input_arm.slot_id);
    debugWrite(", endpoint ");
    debugWriteU64Decimal(input_arm.endpoint_id);
    debugWrite(", length ");
    debugWriteU64Decimal(input_arm.requested_length);
    debugWrite(", TRB 0x");
    debugWriteHex64(@intCast(input_arm.expected_event_trb_pointer));
    debugWrite(", buffer 0x");
    debugWriteHex64(@intCast(input_arm.buffer_address));
    debugWrite("; waiting for QEMU key injection\r\n");

    const keyboard_report = xhci.waitHidKeyboardInput(controller, &ownership, input_arm) orelse
        xhciFailure("HID interrupt-IN transfer did not return the injected key-press report");
    if (keyboard_report.first_key != 0x04) {
        xhciFailure("first HID report was not the injected A-key press");
    }
    if (ownership.interrupts_enabled and keyboard_report.interrupt_count == 0) {
        xhciFailure("A-key press completed without an xHCI MSI-X interrupt");
    }
    debugWrite("HID keyboard press report received: completion ");
    debugWriteU64Decimal(keyboard_report.completion_code);
    debugWrite(", residual ");
    debugWriteU64Decimal(keyboard_report.transfer_residual);
    debugWrite(", length ");
    debugWriteU64Decimal(keyboard_report.report_length);
    debugWrite(", MSI-X interrupts ");
    debugWriteU64Decimal(keyboard_report.interrupt_count);
    debugWrite(", modifier 0x");
    debugWriteHex8(keyboard_report.modifier);
    debugWrite(", keys");
    for (keyboard_report.keys) |key| {
        debugWrite(" 0x");
        debugWriteHex8(key);
    }
    debugWrite("\r\n");

    var event_queue = keyboard_input.Queue.init();
    var previous_keys = std.mem.zeroes([6]u8);
    var previous_modifiers: u8 = 0;
    if (event_queue.applyHidReport(
        &previous_keys,
        &previous_modifiers,
        keyboard_report.modifier,
        keyboard_report.keys,
    ) != 1) {
        xhciFailure("A-key press did not produce exactly one input event");
    }

    const release_arm = xhci.armNextHidKeyboardInput(
        controller,
        &mutable_hid_endpoint,
        allocator,
    ) orelse xhciFailure("second HID interrupt-IN transfer could not be armed");
    debugWrite("HID release transfer armed: slot ");
    debugWriteU64Decimal(release_arm.slot_id);
    debugWrite(", endpoint ");
    debugWriteU64Decimal(release_arm.endpoint_id);
    debugWrite(", length ");
    debugWriteU64Decimal(release_arm.requested_length);
    debugWrite(", TRB 0x");
    debugWriteHex64(@intCast(release_arm.expected_event_trb_pointer));
    debugWrite(", buffer 0x");
    debugWriteHex64(@intCast(release_arm.buffer_address));
    debugWrite("; waiting for key release\r\n");

    const release_report = xhci.waitHidKeyboardInput(controller, &ownership, release_arm) orelse
        xhciFailure("HID interrupt-IN transfer did not return the key-release report");
    if (release_report.first_key != 0) {
        xhciFailure("second HID report was not an all-keys-released report");
    }
    for (release_report.keys) |key| {
        if (key != 0) xhciFailure("release report retained a pressed key usage");
    }
    if (ownership.interrupts_enabled and release_report.interrupt_count == 0) {
        xhciFailure("key release completed without an xHCI MSI-X interrupt");
    }
    debugWrite("HID keyboard release report received: completion ");
    debugWriteU64Decimal(release_report.completion_code);
    debugWrite(", residual ");
    debugWriteU64Decimal(release_report.transfer_residual);
    debugWrite(", length ");
    debugWriteU64Decimal(release_report.report_length);
    debugWrite(", MSI-X interrupts ");
    debugWriteU64Decimal(release_report.interrupt_count);
    debugWrite(", modifier 0x");
    debugWriteHex8(release_report.modifier);
    debugWrite(", keys");
    for (release_report.keys) |key| {
        debugWrite(" 0x");
        debugWriteHex8(key);
    }
    debugWrite("\r\n");

    if (event_queue.applyHidReport(
        &previous_keys,
        &previous_modifiers,
        release_report.modifier,
        release_report.keys,
    ) != 1 or event_queue.count() != 2 or event_queue.dropped != 0) {
        xhciFailure("press/release reports did not produce two ordered input events");
    }
    const press_event = event_queue.pop() orelse xhciFailure("keyboard press event was missing");
    const release_event = event_queue.pop() orelse xhciFailure("keyboard release event was missing");
    if (press_event.sequence != 1 or press_event.source != .usb_hid or
        press_event.action != .pressed or press_event.usage != 0x04 or press_event.ascii != 'a' or
        release_event.sequence != 2 or release_event.source != .usb_hid or
        release_event.action != .released or release_event.usage != 0x04 or release_event.ascii != 'a' or
        event_queue.pop() != null)
    {
        xhciFailure("device-independent keyboard event ordering or translation failed");
    }

    debugWrite("USB keyboard input verified: HID usage 0x");
    debugWriteHex8(press_event.usage);
    debugWrite(" (A), slot ");
    debugWriteU64Decimal(keyboard_report.slot_id);
    debugWrite(", endpoint ");
    debugWriteU64Decimal(keyboard_report.endpoint_id);
    debugWrite(", press TRB 0x");
    debugWriteHex64(keyboard_report.event_trb_pointer);
    debugWrite(", release TRB 0x");
    debugWriteHex64(release_report.event_trb_pointer);
    debugWrite("\r\n");
    debugWrite("Keyboard event queue verified: #1 USB usage 0x04 pressed -> 'a'; #2 USB usage 0x04 released -> 'a'; dropped 0\r\n");
    const shell_interrupt_baseline = xhci.interruptCount();
    runUsbShell(controller, &ownership, &mutable_hid_endpoint, allocator, console);
    const shell_interrupt_count = xhci.interruptCount() - shell_interrupt_baseline;
    if (ownership.interrupts_enabled and shell_interrupt_count == 0) {
        xhciFailure("interactive shell completed without xHCI MSI-X input interrupts");
    }
    debugWrite("xHCI shell MSI-X input verified: ");
    debugWriteU64Decimal(shell_interrupt_count);
    debugWrite(" interrupt(s) after the shell arm marker\r\n");
    return true;
}

fn runUsbShell(
    controller: xhci.Controller,
    ownership: *xhci.Ownership,
    endpoint: *xhci.HidEndpoint,
    allocator: *memory.FrameAllocator,
    graphical_console: *framebuffer_console.Console,
) void {
    const expected_commands = [_][]const u8{ "help", "cpu", "mem", "scroll", "clear", "help", "nope", "", "help", "help" };
    const expected_responses = [_]shell.Response{ .help, .cpu, .memory, .scroll, .clear_screen, .help, .unknown, .empty, .help, .help };
    var command_shell = shell.Shell.init();
    var previous_keys = std.mem.zeroes([6]u8);
    var previous_modifiers: u8 = 0;
    var report_count: u32 = 0;
    var completed_commands: usize = 0;
    var marker_printed = false;

    while (report_count < 176) : (report_count += 1) {
        const arm = xhci.armNextHidKeyboardInput(
            controller,
            endpoint,
            allocator,
        ) orelse xhciFailure("shell HID input transfer could not be armed");
        if (!marker_printed) {
            debugWrite("ZigOs shell input armed: commands help cpu mem scroll clear; waiting for QEMU session\r\n");
            marker_printed = true;
        }
        const report = xhci.waitHidKeyboardInput(controller, ownership, arm) orelse
            xhciFailure("shell HID input transfer did not complete");
        var event_queue = keyboard_input.Queue.init();
        _ = event_queue.applyHidReport(
            &previous_keys,
            &previous_modifiers,
            report.modifier,
            report.keys,
        );
        while (event_queue.pop()) |event| {
            if (event.action == .pressed and event.usage == 0x52) {
                const recalled = command_shell.recallPrevious();
                if (!std.mem.eql(u8, recalled, "help")) {
                    xhciFailure("Up-arrow history recall did not restore the previous help command");
                }
                graphical_console.write(recalled);
                debugWrite("Framebuffer history recall verified: Up -> help\r\n");
                continue;
            }
            if (event.action == .pressed and event.ascii != 0 and event.ascii != '\n') {
                graphical_console.put(event.ascii);
            }
            if (command_shell.feed(event)) |response| {
                graphical_console.put('\n');
                if (completed_commands >= expected_commands.len) {
                    xhciFailure("native shell executed more commands than expected");
                }
                const command = command_shell.executedCommand();
                const response_text = shell.Shell.responseText(response);
                const expected_command = expected_commands[completed_commands];
                const expected_response = expected_responses[completed_commands];
                if (!std.mem.eql(u8, command, expected_command) or
                    response != expected_response or
                    command_shell.command_count != completed_commands + 1 or
                    command_shell.rejected_characters != 0)
                {
                    xhciFailure("persistent native shell command order or dispatch failed");
                }

                debugWrite("zigos> ");
                debugWrite(command);
                debugWrite("\r\n");
                if (response != .empty) {
                    debugWrite(response_text);
                    debugWrite("\r\n");
                }
                completed_commands += 1;

                if (completed_commands == 1) {
                    graphical_console.write(response_text);
                    debugWrite("Framebuffer line editing verified: helx<BS>p -> help\r\n");
                } else if (response == .scroll) {
                    graphical_console.write(response_text);
                    var line_index: usize = 0;
                    while (line_index < 32) : (line_index += 1) {
                        graphical_console.put('\n');
                        graphical_console.write("scroll line");
                    }
                    const scroll_report = graphical_console.report();
                    if (scroll_report.cursor_row != 36 or scroll_report.cursor_column != 11 or
                        scroll_report.lines != 43 or scroll_report.writes != 531 or
                        scroll_report.newlines != 42 or scroll_report.backspaces != 1 or
                        scroll_report.scrolls != 6 or scroll_report.resets != 0 or
                        scroll_report.checksum != 0x9F06_BA73_625A_D44D)
                    {
                        xhciFailure("framebuffer scroll state before clear was not deterministic");
                    }
                    debugWrite("Framebuffer scrolling verified before clear: 32 lines, 37 rows, 6 scrolls, checksum 0x");
                    debugWriteHex64(scroll_report.checksum);
                    debugWrite("\r\n");
                } else if (response == .clear_screen) {
                    graphical_console.reset();
                    graphical_console.write("zigos> ");
                    const clear_report = graphical_console.report();
                    if (clear_report.cursor_row != 0 or clear_report.cursor_column != 7 or
                        clear_report.lines != 1 or clear_report.glyphs != 7 or
                        clear_report.writes != 7 or clear_report.newlines != 0 or
                        clear_report.backspaces != 0 or clear_report.scrolls != 0 or
                        clear_report.resets != 1 or
                        !clear_report.cursor_visible or clear_report.cursor_draws != 2 or
                        clear_report.cursor_erases != 1 or
                        clear_report.display_lit_pixels != clear_report.lit_pixels + cursor_pixel_count or
                        clear_report.display_checksum == clear_report.checksum or
                        clear_report.checksum != 0x5E87_5379_DEFF_239D)
                    {
                        xhciFailure("framebuffer clear did not reset pixels, cursor, and accounting");
                    }
                    debugWrite("Framebuffer clear verified: cursor row 0, column 7, writes 7, resets 1, checksum 0x");
                    debugWriteHex64(clear_report.checksum);
                    debugWrite("\r\n");
                    continue;
                } else if (response == .empty) {
                    graphical_console.write("zigos> ");
                    debugWrite("Framebuffer empty command verified: prompt continued without an error response\r\n");
                    continue;
                } else {
                    graphical_console.write(response_text);
                    if (response == .unknown) {
                        debugWrite("Framebuffer unknown command verified: nope -> error: unknown command\r\n");
                    }
                }

                if (completed_commands < expected_commands.len) {
                    graphical_console.put('\n');
                    graphical_console.write("zigos> ");
                    continue;
                }

                const console_report = graphical_console.report();
                if (console_report.cursor_row != 8 or console_report.cursor_column != 35 or
                    console_report.lines != 9 or console_report.glyphs != 178 or
                    console_report.writes != 178 or console_report.newlines != 8 or
                    console_report.backspaces != 0 or console_report.scrolls != 0 or
                    console_report.resets != 1 or command_shell.history_recalls != 1 or
                    !console_report.cursor_visible or console_report.cursor_draws != 31 or
                    console_report.cursor_erases != 30 or
                    console_report.display_lit_pixels != 9512 or
                    console_report.display_checksum != 0x030F_BD61_54A5_D1BD or
                    console_report.lit_pixels != 9492 or
                    console_report.checksum != 0x4721_B2F0_411D_5331)
                {
                    xhciFailure("history-recalled framebuffer shell state was not deterministic");
                }
                debugWrite("Framebuffer history shell: cursor row ");
                debugWriteUsizeDecimal(console_report.cursor_row);
                debugWrite(", column ");
                debugWriteUsizeDecimal(console_report.cursor_column);
                debugWrite(", lines ");
                debugWriteUsizeDecimal(console_report.lines);
                debugWrite(", writes ");
                debugWriteUsizeDecimal(console_report.writes);
                debugWrite(", newlines ");
                debugWriteUsizeDecimal(console_report.newlines);
                debugWrite(", resets ");
                debugWriteUsizeDecimal(console_report.resets);
                debugWrite(", recalls ");
                debugWriteUsizeDecimal(command_shell.history_recalls);
                debugWrite(", checksum 0x");
                debugWriteHex64(console_report.checksum);
                debugWrite(", cursor visible, draws ");
                debugWriteUsizeDecimal(console_report.cursor_draws);
                debugWrite(", erases ");
                debugWriteUsizeDecimal(console_report.cursor_erases);
                debugWrite(", display checksum 0x");
                debugWriteHex64(console_report.display_checksum);
                debugWrite("\r\n");
                debugWrite("ZigOs shell session complete: valid, clear, unknown, empty, recovery, history; commands 10, reports ");
                debugWriteU64Decimal(report_count + 1);
                debugWrite(", rejected 0\r\n");
                return;
            }
        }
    }
    xhciFailure("native shell did not complete ten commands within 176 reports");
}

fn xhciFailure(reason: []const u8) noreturn {
    debugWrite("xHCI discovery failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn inspectNvme(
    inventory: pci.Inventory,
    allocator: *memory.FrameAllocator,
    reference: time_reference.Reference,
    interrupt_target: ?u8,
) bool {
    var controller_function: ?pci.Function = null;
    for (inventory.functions[0..inventory.retained_count]) |function| {
        if (function.class_code == 0x01 and function.subclass == 0x08 and function.programming_interface == 0x02) {
            controller_function = function;
            break;
        }
    }

    const function = controller_function orelse {
        debugWrite("NVMe controller not present; continuing without NVMe storage\r\n");
        return false;
    };
    const pci_capabilities = pci.inspectCapabilities(function) orelse
        nvmeFailure("PCI capability list was malformed");
    debugWrite("NVMe PCI capabilities: count ");
    debugWriteU64Decimal(pci_capabilities.count);
    debugWrite(", MSI ");
    if (pci_capabilities.msi_offset) |offset| {
        debugWrite("+0x");
        debugWriteHex8(offset);
    } else {
        debugWrite("absent");
    }
    debugWrite(", MSI-X ");
    if (pci_capabilities.msix_offset) |offset| {
        debugWrite("+0x");
        debugWriteHex8(offset);
    } else {
        debugWrite("absent");
    }
    debugWrite("\r\n");
    if (pci_capabilities.msix_offset != null) {
        const msix = pci.inspectMsix(function) orelse
            nvmeFailure("NVMe PCI MSI-X capability was malformed");
        debugWrite("NVMe MSI-X descriptor: vectors ");
        debugWriteU64Decimal(msix.table_size);
        debugWrite(", table BAR ");
        debugWriteU64Decimal(msix.table_bar_index);
        debugWrite(" +0x");
        debugWriteHex64(msix.table_offset);
        debugWrite(", PBA BAR ");
        debugWriteU64Decimal(msix.pending_bar_index);
        debugWrite(" +0x");
        debugWriteHex64(msix.pending_offset);
        debugWrite("\r\n");
    } else {
        debugWrite("NVMe MSI-X descriptor unavailable; bounded I/O polling will be used\r\n");
    }
    var controller = nvme.initialize(function, allocator, reference, interrupt_target) orelse {
        debugWrite("NVMe initialization diagnostics: BAR 0x");
        debugWriteHex64(nvme.last_bar);
        debugWrite(", mapping present ");
        debugWrite(if (nvme.last_mapping_present) "yes" else "no");
        debugWrite(", stage ");
        debugWrite(nvmeFailureStageName(nvme.last_failure_stage));
        debugWrite(", opcode 0x");
        debugWriteHex8(nvme.last_command_opcode);
        debugWrite(", completion status 0x");
        debugWriteHex16(nvme.last_completion_status);
        debugWrite(", CID ");
        debugWriteU64Decimal(nvme.last_completion_command_id);
        debugWrite(", SQID ");
        debugWriteU64Decimal(nvme.last_completion_queue_id);
        debugWrite(", CSTS 0x");
        debugWriteHex64(nvme.last_controller_status);
        debugWrite(", CC 0x");
        debugWriteHex64(nvme.last_controller_configuration);
        debugWrite("\r\n");
        nvmeFailure("controller reset, admin queue, or Identify command failed");
    };

    debugWrite("NVMe controller active at ");
    debugWriteHex16(function.segment);
    debugWrite(":");
    debugWriteHex8(function.bus);
    debugWrite(":");
    debugWriteHex8(function.device);
    debugWrite(".");
    debugWriteU64Decimal(function.function);
    debugWrite(", vendor 0x");
    debugWriteHex16(function.vendor_id);
    debugWrite(", device 0x");
    debugWriteHex16(function.device_id);
    debugWrite(", BAR 0x");
    debugWriteHex64(@intCast(controller.bar));
    debugWrite("\r\n");

    debugWrite("NVMe capabilities: version ");
    debugWriteU64Decimal(controller.version >> 16);
    debugWrite(".");
    debugWriteU64Decimal((controller.version >> 8) & 0xFF);
    debugWrite(".");
    debugWriteU64Decimal(controller.version & 0xFF);
    debugWrite(", CAP 0x");
    debugWriteHex64(controller.capabilities);
    debugWrite(", max queue entries ");
    debugWriteU64Decimal(controller.maximum_queue_entries);
    debugWrite(", doorbell stride ");
    debugWriteU64Decimal(controller.doorbell_stride);
    debugWrite(", timeout units ");
    debugWriteU64Decimal(controller.timeout_units);
    debugWrite("\r\n");

    debugWrite("NVMe MMIO mapping: 0x");
    debugWriteHex64(controller.mapped_base);
    debugWrite(" + ");
    debugWriteU64Decimal(controller.mapped_bytes);
    debugWrite(" bytes using ");
    debugWriteU64Decimal(controller.mapping_table_pages);
    debugWrite(" new table page(s)\r\n");

    debugWrite("NVMe identity: model \"");
    debugWrite(nvme.terminatedSlice(&controller.model_number));
    debugWrite("\", serial \"");
    debugWrite(nvme.terminatedSlice(&controller.serial_number));
    debugWrite("\", firmware \"");
    debugWrite(nvme.terminatedSlice(&controller.firmware_revision));
    debugWrite("\", namespaces ");
    debugWriteU64Decimal(controller.namespace_count);
    debugWrite("\r\n");

    debugWrite("NVMe namespace ");
    debugWriteU64Decimal(controller.namespace_id);
    debugWrite(": ");
    debugWriteU64Decimal(controller.namespace_size_lbas);
    debugWrite(" LBA(s), capacity ");
    debugWriteU64Decimal(controller.namespace_capacity_lbas);
    debugWrite(" LBA(s) x ");
    debugWriteU64Decimal(controller.logical_block_size);
    debugWrite(" bytes = ");
    debugWriteU64Decimal(controller.capacity_bytes);
    debugWrite(" bytes, metadata ");
    debugWriteU64Decimal(controller.metadata_size);
    debugWrite("\r\n");

    debugWrite("NVMe queues active: admin SQ 0x");
    debugWriteHex64(@intCast(controller.admin_queue.submission_address));
    debugWrite(", admin CQ 0x");
    debugWriteHex64(@intCast(controller.admin_queue.completion_address));
    debugWrite(", I/O SQ 0x");
    debugWriteHex64(@intCast(controller.io_queue.submission_address));
    debugWrite(", I/O CQ 0x");
    debugWriteHex64(@intCast(controller.io_queue.completion_address));
    debugWrite(", depth ");
    debugWriteU64Decimal(controller.io_queue.depth);
    debugWrite("\r\n");

    if (controller.msix_enabled) {
        debugWrite("NVMe MSI-X active: vector 0x");
        debugWriteHex8(controller.interrupt_vector);
        debugWrite(", table index ");
        debugWriteU64Decimal(nvme.io_msix_table_index);
        debugWrite(", target APIC ");
        debugWriteU64Decimal(controller.interrupt_target_apic_id);
        debugWrite(", table 0x");
        debugWriteHex64(@intCast(controller.msix_table_address));
        debugWrite(", vectors ");
        debugWriteU64Decimal(controller.msix_vector_count);
        debugWrite(", mapping table pages ");
        debugWriteU64Decimal(controller.msix_mapping_table_pages);
        debugWrite("\r\n");
    } else {
        debugWrite("NVMe MSI-X unavailable; I/O completion polling retained\r\n");
    }

    const block_zero = nvme.readOneBlock(&controller, allocator, 0) orelse {
        debugWrite("NVMe MSI-X read diagnostics: control 0x");
        debugWriteHex16(nvme.last_msix_control);
        debugWrite(", address 0x");
        debugWriteHex64((@as(u64, nvme.last_msix_message_address_high) << 32) |
            nvme.last_msix_message_address_low);
        debugWrite(", data 0x");
        debugWriteHex64(nvme.last_msix_message_data);
        debugWrite(", vector control 0x");
        debugWriteHex64(nvme.last_msix_vector_control);
        debugWrite(", interrupt ");
        debugWriteU64Decimal(nvme.last_interrupt_baseline);
        debugWrite(" -> ");
        debugWriteU64Decimal(nvme.last_interrupt_observed);
        debugWrite(", CQ status 0x");
        debugWriteHex16(nvme.last_completion_status_after_interrupt_wait);
        debugWrite(", expected phase ");
        debugWriteU64Decimal(nvme.last_completion_phase_expected);
        debugWrite(", timeout ");
        debugWrite(if (nvme.last_interrupt_wait_timed_out) "yes" else "no");
        debugWrite("\r\n");
        nvmeFailure("read-only NVM Read command for LBA 0 failed");
    };
    debugWrite("NVMe READ completed: namespace ");
    debugWriteU64Decimal(block_zero.namespace_id);
    debugWrite(", LBA ");
    debugWriteU64Decimal(block_zero.lba);
    debugWrite(", ");
    debugWriteU64Decimal(block_zero.byte_count);
    debugWrite(" bytes at 0x");
    debugWriteHex64(@intCast(block_zero.buffer_address));
    debugWrite("\r\n");
    if (controller.msix_enabled) {
        if (block_zero.completion_interrupt_count != 1) {
            nvmeFailure("first NVM Read did not complete through exactly one MSI-X interrupt");
        }
        debugWrite("NVMe MSI-X I/O completion verified: vector 0x");
        debugWriteHex8(controller.interrupt_vector);
        debugWrite(", target APIC ");
        debugWriteU64Decimal(controller.interrupt_target_apic_id);
        debugWrite(", interrupt count ");
        debugWriteU64Decimal(block_zero.completion_interrupt_count);
        debugWrite("\r\n");
    }
    debugWrite("NVMe LBA 0 first 16 bytes:");
    for (block_zero.first_bytes) |byte| {
        debugWrite(" ");
        debugWriteHex8(byte);
    }
    debugWrite("\r\nNVMe LBA 0 FNV-1a64: 0x");
    debugWriteHex64(block_zero.fnv1a64);
    debugWrite(", MBR signature 0x");
    debugWriteHex16(block_zero.mbr_signature);
    debugWrite("\r\n");

    const protective_mbr = partition.parseMbr(nvme.readBuffer(block_zero)) orelse
        nvmeFailure("LBA 0 did not contain a valid protective MBR");
    var protective_partition: ?partition.Partition = null;
    for (protective_mbr.partitions) |candidate| {
        if (candidate.partition_type == 0xEE and candidate.first_lba == 1 and candidate.sector_count != 0) {
            protective_partition = candidate;
            break;
        }
    }
    const protective = protective_partition orelse
        nvmeFailure("protective MBR did not contain a type 0xEE partition from LBA 1");
    debugWrite("NVMe protective MBR verified: type 0x");
    debugWriteHex8(protective.partition_type);
    debugWrite(", first LBA ");
    debugWriteU64Decimal(protective.first_lba);
    debugWrite(", sectors ");
    debugWriteU64Decimal(protective.sector_count);
    debugWrite("\r\n");

    const header_block = nvme.readOneBlock(&controller, allocator, 1) orelse
        nvmeFailure("primary GPT header read failed");
    const header = gpt.parseHeader(nvme.readBuffer(header_block), controller.namespace_size_lbas) orelse
        nvmeFailure("primary GPT header signature, bounds, or CRC validation failed");
    if (controller.logical_block_size % header.partition_entry_size != 0) {
        nvmeFailure("GPT entry size did not divide the NVMe logical block size");
    }

    const block_size: u64 = controller.logical_block_size;
    const entry_array_sectors = (header.partition_array_bytes + block_size - 1) / block_size;
    var crc_state = gpt.crc32Begin();
    var remaining_bytes = header.partition_array_bytes;
    var global_entry_index: u32 = 0;
    var populated_entries: u32 = 0;
    var efi_partition: ?gpt.PartitionEntry = null;
    var sector_index: u64 = 0;
    while (sector_index < entry_array_sectors) : (sector_index += 1) {
        const entry_block = nvme.readOneBlock(
            &controller,
            allocator,
            header.partition_entry_lba + sector_index,
        ) orelse nvmeFailure("GPT partition-entry-array read failed");
        const bytes = nvme.readBuffer(entry_block);
        const bytes_this_sector: usize = @intCast(@min(remaining_bytes, @as(u64, bytes.len)));
        crc_state = gpt.crc32Update(crc_state, bytes[0..bytes_this_sector]);

        var offset: usize = 0;
        const entry_size: usize = @intCast(header.partition_entry_size);
        while (offset + entry_size <= bytes_this_sector and global_entry_index < header.partition_entry_count) : ({
            offset += entry_size;
            global_entry_index += 1;
        }) {
            const entry = gpt.parsePartitionEntry(
                bytes[offset .. offset + entry_size],
                header.partition_entry_size,
                global_entry_index,
            ) orelse nvmeFailure("GPT partition entry was malformed");
            if (!entry.isUnused()) {
                if (!gpt.validatePartitionBounds(header, entry)) {
                    nvmeFailure("GPT partition exceeded the header usable-LBA range");
                }
                populated_entries += 1;
                if (efi_partition == null and entry.isEfiSystemPartition()) efi_partition = entry;
            }
        }
        remaining_bytes -= bytes_this_sector;
    }
    if (remaining_bytes != 0 or global_entry_index != header.partition_entry_count) {
        nvmeFailure("GPT partition array length did not match the header");
    }
    const partition_array_crc = gpt.crc32Finish(crc_state);
    if (partition_array_crc != header.partition_array_crc32) {
        nvmeFailure("GPT partition-entry-array CRC did not match the header");
    }

    const backup_header_block = nvme.readOneBlock(&controller, allocator, header.backup_lba) orelse
        nvmeFailure("backup GPT header read failed");
    const backup_header = gpt.parseHeader(
        nvme.readBuffer(backup_header_block),
        controller.namespace_size_lbas,
    ) orelse nvmeFailure("backup GPT header signature, bounds, or CRC validation failed");
    if (backup_header.current_lba != header.backup_lba or
        backup_header.backup_lba != header.current_lba or
        backup_header.first_usable_lba != header.first_usable_lba or
        backup_header.last_usable_lba != header.last_usable_lba or
        backup_header.partition_entry_count != header.partition_entry_count or
        backup_header.partition_entry_size != header.partition_entry_size or
        backup_header.partition_array_crc32 != header.partition_array_crc32 or
        !std.mem.eql(u8, &backup_header.disk_guid, &header.disk_guid))
    {
        nvmeFailure("primary and backup GPT metadata did not cross-validate");
    }

    var backup_crc_state = gpt.crc32Begin();
    var backup_remaining_bytes = backup_header.partition_array_bytes;
    var backup_sector_index: u64 = 0;
    while (backup_sector_index < entry_array_sectors) : (backup_sector_index += 1) {
        const backup_entry_block = nvme.readOneBlock(
            &controller,
            allocator,
            backup_header.partition_entry_lba + backup_sector_index,
        ) orelse nvmeFailure("backup GPT partition-entry-array read failed");
        const backup_bytes = nvme.readBuffer(backup_entry_block);
        const backup_bytes_this_sector: usize = @intCast(@min(
            backup_remaining_bytes,
            @as(u64, backup_bytes.len),
        ));
        backup_crc_state = gpt.crc32Update(
            backup_crc_state,
            backup_bytes[0..backup_bytes_this_sector],
        );
        backup_remaining_bytes -= backup_bytes_this_sector;
    }
    const backup_partition_array_crc = gpt.crc32Finish(backup_crc_state);
    if (backup_remaining_bytes != 0 or
        backup_partition_array_crc != backup_header.partition_array_crc32)
    {
        nvmeFailure("backup GPT partition-entry-array CRC did not match its header");
    }

    debugWrite("NVMe GPT header verified: revision ");
    debugWriteU64Decimal(header.revision >> 16);
    debugWrite(".");
    debugWriteU64Decimal((header.revision >> 8) & 0xFF);
    debugWrite(", current LBA ");
    debugWriteU64Decimal(header.current_lba);
    debugWrite(", backup LBA ");
    debugWriteU64Decimal(header.backup_lba);
    debugWrite(", usable ");
    debugWriteU64Decimal(header.first_usable_lba);
    debugWrite("-");
    debugWriteU64Decimal(header.last_usable_lba);
    debugWrite(", header CRC 0x");
    debugWriteHex64(header.header_crc32);
    debugWrite("\r\n");
    debugWrite("NVMe GPT partition array verified: ");
    debugWriteU64Decimal(header.partition_entry_count);
    debugWrite(" entries x ");
    debugWriteU64Decimal(header.partition_entry_size);
    debugWrite(" bytes at LBA ");
    debugWriteU64Decimal(header.partition_entry_lba);
    debugWrite(", sectors ");
    debugWriteU64Decimal(entry_array_sectors);
    debugWrite(", populated ");
    debugWriteU64Decimal(populated_entries);
    debugWrite(", CRC 0x");
    debugWriteHex64(partition_array_crc);
    debugWrite("\r\n");
    debugWrite("NVMe backup GPT verified: current LBA ");
    debugWriteU64Decimal(backup_header.current_lba);
    debugWrite(", primary LBA ");
    debugWriteU64Decimal(backup_header.backup_lba);
    debugWrite(", entries LBA ");
    debugWriteU64Decimal(backup_header.partition_entry_lba);
    debugWrite(", header CRC 0x");
    debugWriteHex64(backup_header.header_crc32);
    debugWrite(", array CRC 0x");
    debugWriteHex64(backup_partition_array_crc);
    debugWrite("\r\n");

    const efi = efi_partition orelse nvmeFailure("GPT did not contain an EFI System Partition");
    const efi_sector_count = efi.sectorCount() orelse
        nvmeFailure("EFI System Partition LBA range overflowed");
    debugWrite("NVMe EFI System Partition: index ");
    debugWriteU64Decimal(efi.index);
    debugWrite(", LBA ");
    debugWriteU64Decimal(efi.first_lba);
    debugWrite(" + ");
    debugWriteU64Decimal(efi_sector_count);
    debugWrite(" sectors, name \"");
    debugWrite(efi.nameSlice());
    debugWrite("\"\r\n");

    const volume_block = nvme.readOneBlock(&controller, allocator, efi.first_lba) orelse
        nvmeFailure("EFI System Partition boot-sector read failed");
    const volume = fat.parseBootSector(nvme.readBuffer(volume_block), efi.first_lba) orelse
        nvmeFailure("EFI System Partition did not contain a valid FAT BPB");
    if (@as(u64, volume.total_sectors) > efi_sector_count) {
        nvmeFailure("FAT volume geometry exceeded the GPT partition bounds");
    }
    debugWrite("NVMe FAT volume verified: ");
    debugWrite(switch (volume.kind) {
        .fat12 => "FAT12",
        .fat16 => "FAT16",
        .fat32 => "FAT32",
    });
    debugWrite(", label \"");
    debugWrite(fat.terminatedSlice(&volume.volume_label));
    debugWrite("\", filesystem \"");
    debugWrite(fat.terminatedSlice(&volume.filesystem_label));
    debugWrite("\", ");
    debugWriteU64Decimal(volume.total_sectors);
    debugWrite(" sectors, first FAT LBA ");
    debugWriteU64Decimal(volume.first_fat_lba);
    debugWrite(", root LBA ");
    debugWriteU64Decimal(volume.root_directory_lba);
    debugWrite("\r\n");
    walkNvmeFatBootPath(&controller, allocator, volume);
    return true;
}

fn walkNvmeFatBootPath(
    controller: *nvme.Controller,
    allocator: *memory.FrameAllocator,
    volume: fat.Volume,
) void {
    if (volume.bytes_per_sector != controller.logical_block_size) {
        nvmeFailure("FAT sector size did not match the NVMe logical block size");
    }
    const efi_entry = findNvmeRootDirectoryEntry(controller, allocator, volume, "EFI") orelse
        nvmeFailure("NVMe FAT root directory did not contain EFI");
    if (!efi_entry.isDirectory() or efi_entry.first_cluster < 2) {
        nvmeFailure("NVMe FAT EFI entry was not a valid directory");
    }
    const boot_entry = findNvmeClusterDirectoryEntry(
        controller,
        allocator,
        volume,
        efi_entry.first_cluster,
        "BOOT",
    ) orelse nvmeFailure("NVMe FAT EFI directory did not contain BOOT");
    if (!boot_entry.isDirectory() or boot_entry.first_cluster < 2) {
        nvmeFailure("NVMe FAT EFI/BOOT entry was not a valid directory");
    }
    const loader_entry = findNvmeClusterDirectoryEntry(
        controller,
        allocator,
        volume,
        boot_entry.first_cluster,
        "BOOTX64.EFI",
    ) orelse nvmeFailure("NVMe FAT EFI/BOOT did not contain BOOTX64.EFI");
    if (loader_entry.isDirectory() or loader_entry.first_cluster < 2 or loader_entry.file_size == 0) {
        nvmeFailure("NVMe FAT BOOTX64.EFI entry was invalid");
    }

    debugWrite("NVMe FAT path resolved: EFI cluster ");
    debugWriteU64Decimal(efi_entry.first_cluster);
    debugWrite(" -> BOOT cluster ");
    debugWriteU64Decimal(boot_entry.first_cluster);
    debugWrite(" -> BOOTX64.EFI cluster ");
    debugWriteU64Decimal(loader_entry.first_cluster);
    debugWrite("\r\nNVMe FAT boot file found: EFI/BOOT/BOOTX64.EFI, size ");
    debugWriteU64Decimal(loader_entry.file_size);
    debugWrite(" bytes\r\n");

    const stream = streamNvmeFatFile(controller, allocator, volume, loader_entry);
    const image = pe.parse(&stream.first_sector) orelse
        nvmeFailure("NVMe FAT BOOTX64.EFI did not contain valid DOS/PE headers");
    if (!image.amd64 or !image.pe32_plus or !image.efi_application or
        image.size_of_headers > stream.byte_count or image.size_of_image == 0)
    {
        nvmeFailure("NVMe FAT BOOTX64.EFI was not a valid AMD64 EFI application");
    }

    debugWrite("NVMe FAT file streamed: ");
    debugWriteU64Decimal(stream.byte_count);
    debugWrite(" bytes across ");
    debugWriteU64Decimal(stream.cluster_count);
    debugWrite(" cluster(s), last cluster ");
    debugWriteU64Decimal(stream.last_cluster);
    debugWrite(", FNV-1a64 0x");
    debugWriteHex64(stream.fnv1a64);
    debugWrite("\r\nNVMe on-disk PE verified: AMD64 PE32+, EFI subsystem ");
    debugWriteU64Decimal(image.subsystem);
    debugWrite(", sections ");
    debugWriteU64Decimal(image.section_count);
    debugWrite(", entry RVA 0x");
    debugWriteHex64(image.entry_point_rva);
    debugWrite(", image size ");
    debugWriteU64Decimal(image.size_of_image);
    debugWrite("\r\n");
}

fn findNvmeRootDirectoryEntry(
    controller: *nvme.Controller,
    allocator: *memory.FrameAllocator,
    volume: fat.Volume,
    expected_name: []const u8,
) ?fat.DirectoryEntry {
    if (volume.kind == .fat32) {
        return findNvmeClusterDirectoryEntry(
            controller,
            allocator,
            volume,
            volume.root_cluster,
            expected_name,
        );
    }
    var sector_index: u32 = 0;
    while (sector_index < volume.root_directory_sectors) : (sector_index += 1) {
        const sector = nvme.readOneBlock(
            controller,
            allocator,
            volume.root_directory_lba + sector_index,
        ) orelse nvmeFailure("NVMe FAT root-directory sector read failed");
        const directory = fat.parseDirectorySector(nvme.readBuffer(sector)) orelse
            nvmeFailure("NVMe FAT root-directory decoding failed");
        if (findNamedEntry(directory, expected_name)) |entry| return entry;
        if (directory.end_of_directory) return null;
    }
    return null;
}

fn findNvmeClusterDirectoryEntry(
    controller: *nvme.Controller,
    allocator: *memory.FrameAllocator,
    volume: fat.Volume,
    initial_cluster: u32,
    expected_name: []const u8,
) ?fat.DirectoryEntry {
    var cluster = initial_cluster;
    var traversed_clusters: usize = 0;
    while (traversed_clusters < 4096) : (traversed_clusters += 1) {
        const first_lba = fat.clusterFirstLba(volume, cluster) orelse
            nvmeFailure("NVMe FAT directory cluster was outside the data range");
        var sector_index: u8 = 0;
        while (sector_index < volume.sectors_per_cluster) : (sector_index += 1) {
            const sector = nvme.readOneBlock(
                controller,
                allocator,
                first_lba + sector_index,
            ) orelse nvmeFailure("NVMe FAT directory-cluster sector read failed");
            const directory = fat.parseDirectorySector(nvme.readBuffer(sector)) orelse
                nvmeFailure("NVMe FAT directory-cluster decoding failed");
            if (findNamedEntry(directory, expected_name)) |entry| return entry;
            if (directory.end_of_directory) return null;
        }
        switch (readNvmeFatClusterLink(controller, allocator, volume, cluster)) {
            .next => |next_cluster| cluster = next_cluster,
            .end => return null,
            .free => nvmeFailure("NVMe FAT directory chain reached a free entry"),
            .bad => nvmeFailure("NVMe FAT directory chain reached a bad entry"),
        }
    }
    nvmeFailure("NVMe FAT directory chain exceeded the traversal limit");
}

fn streamNvmeFatFile(
    controller: *nvme.Controller,
    allocator: *memory.FrameAllocator,
    volume: fat.Volume,
    entry: fat.DirectoryEntry,
) FatFileStream {
    var result = FatFileStream{
        .byte_count = 0,
        .cluster_count = 0,
        .last_cluster = 0,
        .fnv1a64 = 0xCBF2_9CE4_8422_2325,
        .first_sector = undefined,
    };
    var remaining: u64 = entry.file_size;
    var cluster = entry.first_cluster;
    var first_sector_copied = false;
    while (remaining != 0 and result.cluster_count < 1_000_000) {
        const first_lba = fat.clusterFirstLba(volume, cluster) orelse
            nvmeFailure("NVMe FAT file cluster was outside the data range");
        result.cluster_count += 1;
        result.last_cluster = cluster;
        var sector_index: u8 = 0;
        while (sector_index < volume.sectors_per_cluster and remaining != 0) : (sector_index += 1) {
            const sector = nvme.readOneBlock(
                controller,
                allocator,
                first_lba + sector_index,
            ) orelse nvmeFailure("NVMe FAT file sector read failed");
            const bytes = nvme.readBuffer(sector);
            const take: usize = @intCast(@min(remaining, @as(u64, bytes.len)));
            if (!first_sector_copied) {
                if (bytes.len < result.first_sector.len) {
                    nvmeFailure("NVMe FAT first file sector was smaller than 512 bytes");
                }
                @memcpy(&result.first_sector, bytes[0..result.first_sector.len]);
                first_sector_copied = true;
            }
            result.fnv1a64 = fnv1aUpdate(result.fnv1a64, bytes[0..take]);
            result.byte_count += take;
            remaining -= take;
        }
        const link = readNvmeFatClusterLink(controller, allocator, volume, cluster);
        if (remaining == 0) {
            switch (link) {
                .end => {},
                else => nvmeFailure("NVMe FAT file data ended before its cluster chain"),
            }
            break;
        }
        switch (link) {
            .next => |next_cluster| cluster = next_cluster,
            .end => nvmeFailure("NVMe FAT cluster chain ended before the declared file size"),
            .free => nvmeFailure("NVMe FAT file chain reached a free entry"),
            .bad => nvmeFailure("NVMe FAT file chain reached a bad entry"),
        }
    }
    if (remaining != 0 or result.byte_count != entry.file_size or !first_sector_copied) {
        nvmeFailure("NVMe FAT file stream did not consume the declared size");
    }
    return result;
}

fn readNvmeFatClusterLink(
    controller: *nvme.Controller,
    allocator: *memory.FrameAllocator,
    volume: fat.Volume,
    cluster: u32,
) fat.ClusterLink {
    const location = fat.fatEntryLocation(volume, cluster) orelse
        nvmeFailure("NVMe FAT cluster-entry location was invalid");
    const sector = nvme.readOneBlock(controller, allocator, location.lba) orelse
        nvmeFailure("NVMe FAT cluster-link sector read failed");
    return fat.decodeClusterLink(volume, cluster, nvme.readBuffer(sector)) orelse
        nvmeFailure("NVMe FAT cluster-link value was invalid");
}

fn nvmeFailureStageName(stage: nvme.FailureStage) []const u8 {
    return switch (stage) {
        .none => "none",
        .pci_command => "pci-command",
        .bar => "bar",
        .mapping => "mapping",
        .capabilities => "capabilities",
        .disable => "disable",
        .allocation => "allocation",
        .enable => "enable",
        .identify_controller => "identify-controller",
        .namespace_list => "namespace-list",
        .identify_namespace => "identify-namespace",
        .create_io_queues => "create-io-queues",
        .msix => "msix",
        .io_read => "io-read",
    };
}

fn nvmeFailure(reason: []const u8) noreturn {
    debugWrite("NVMe failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn inspectAhci(inventory: pci.Inventory, allocator: *memory.FrameAllocator, interrupt_target: ?u8) bool {
    var controller_function: ?pci.Function = null;
    for (inventory.functions[0..inventory.retained_count]) |function| {
        if (function.class_code == 0x01 and function.subclass == 0x06 and function.programming_interface == 0x01) {
            controller_function = function;
            break;
        }
    }

    const function = controller_function orelse {
        debugWrite("AHCI controller not present; continuing with another storage backend\r\n");
        return false;
    };
    const controller = ahci.inspect(function) orelse {
        debugWrite("AHCI controller registers were unusable; continuing with another storage backend\r\n");
        return false;
    };

    const pci_capabilities = pci.inspectCapabilities(function) orelse
        ahciFailure("PCI capability list was malformed");
    debugWrite("AHCI PCI capabilities: count ");
    debugWriteU64Decimal(pci_capabilities.count);
    debugWrite(", MSI ");
    if (pci_capabilities.msi_offset) |offset| {
        debugWrite("+0x");
        debugWriteHex8(offset);
    } else {
        debugWrite("absent");
    }
    debugWrite(", MSI-X ");
    if (pci_capabilities.msix_offset) |offset| {
        debugWrite("+0x");
        debugWriteHex8(offset);
    } else {
        debugWrite("absent");
    }
    debugWrite("\r\n");

    debugWrite("AHCI controller active at ");
    debugWriteHex16(function.segment);
    debugWrite(":");
    debugWriteHex8(function.bus);
    debugWrite(":");
    debugWriteHex8(function.device);
    debugWrite(".");
    debugWriteU64Decimal(function.function);
    debugWrite(", ABAR 0x");
    debugWriteHex64(@intCast(controller.abar));
    debugWrite(", version 0x");
    debugWriteHex64(controller.version);
    debugWrite("\r\n");
    debugWrite("AHCI capabilities: ");
    debugWriteU64Decimal(controller.declared_port_count);
    debugWrite(" declared ports, ");
    debugWriteU64Decimal(controller.command_slot_count);
    debugWrite(" command slots, PI 0x");
    debugWriteHex64(controller.ports_implemented);
    debugWrite(if (controller.supports_64_bit_dma) ", 64-bit DMA" else ", 32-bit DMA");
    debugWrite(if (controller.supports_ncq) ", NCQ\r\n" else ", no NCQ\r\n");
    debugWrite("AHCI port inventory: ");
    debugWriteU64Decimal(controller.implemented_port_count);
    debugWrite(" implemented, ");
    debugWriteU64Decimal(controller.active_device_count);
    debugWrite(" active device(s)\r\n");

    for (controller.ports[0..controller.retained_port_count]) |port| {
        debugWrite("AHCI port ");
        debugWriteU64Decimal(port.index);
        debugWrite(": ");
        debugWrite(ahciDeviceTypeName(port.device_type));
        debugWrite(if (port.active) " active" else " inactive");
        debugWrite(", SSTS 0x");
        debugWriteHex64(port.sata_status);
        debugWrite(", SIG 0x");
        debugWriteHex64(port.signature);
        debugWrite(", TFD 0x");
        debugWriteHex64(port.task_file_data);
        debugWrite(", CMD 0x");
        debugWriteHex64(port.command);
        debugWrite("\r\n");
    }
    var active_sata_count: usize = 0;
    for (controller.ports[0..controller.retained_port_count]) |port| {
        if (port.active and port.device_type == .sata) active_sata_count += 1;
    }
    if (active_sata_count == 0) {
        debugWrite("AHCI controller has no active SATA devices; continuing with NVMe storage\r\n");
        return false;
    }
    const identity = ahci.identifyFirstSata(controller, allocator, interrupt_target) orelse
        ahciFailure("ATA IDENTIFY DEVICE DMA command did not complete successfully");
    debugWrite("ATA IDENTIFY completed on port ");
    debugWriteU64Decimal(identity.port_index);
    debugWrite(": model \"");
    debugWrite(ahci.terminatedSlice(&identity.model));
    debugWrite("\", serial \"");
    debugWrite(ahci.terminatedSlice(&identity.serial_number));
    debugWrite("\", firmware \"");
    debugWrite(ahci.terminatedSlice(&identity.firmware_revision));
    debugWrite("\"\r\n");
    debugWrite("SATA capacity: ");
    debugWriteU64Decimal(identity.sector_count);
    debugWrite(" sectors x ");
    debugWriteU64Decimal(identity.logical_sector_size);
    debugWrite(" bytes = ");
    debugWriteU64Decimal(identity.capacity_bytes);
    debugWrite(" bytes");
    debugWrite(if (identity.lba48_supported) ", LBA48" else ", LBA28");
    debugWrite(if (identity.ncq_supported) ", NCQ" else ", no NCQ");
    debugWrite(", queue depth ");
    debugWriteU64Decimal(identity.queue_depth);
    debugWrite("\r\n");
    debugWrite("AHCI DMA structures: CLB 0x");
    debugWriteHex64(@intCast(identity.command_list_address));
    debugWrite(", FB 0x");
    debugWriteHex64(@intCast(identity.received_fis_address));
    debugWrite(", CTBA 0x");
    debugWriteHex64(@intCast(identity.command_table_address));
    debugWrite(", data 0x");
    debugWriteHex64(@intCast(identity.identify_buffer_address));
    debugWrite(", transferred ");
    debugWriteU64Decimal(identity.transferred_bytes);
    debugWrite(" bytes\r\n");
    if (identity.msi_enabled) {
        if (identity.completion_interrupt_count != 1) {
            ahciFailure("ATA IDENTIFY did not complete through exactly one MSI interrupt");
        }
        debugWrite("AHCI MSI active: capability +0x");
        debugWriteHex8(identity.msi_capability_offset);
        debugWrite(", vector 0x");
        debugWriteHex8(identity.interrupt_vector);
        debugWrite(", target APIC ");
        debugWriteU64Decimal(identity.interrupt_target_apic_id);
        debugWrite(if (identity.msi_address_64_bit) ", 64-bit address" else ", 32-bit address");
        debugWrite(", control 0x");
        debugWriteHex16(identity.msi_control);
        debugWrite("\r\n");
        debugWrite("AHCI IDENTIFY MSI completion verified: interrupt count ");
        debugWriteU64Decimal(identity.completion_interrupt_count);
        debugWrite(", global IS 0x");
        debugWriteHex64(identity.completion_global_status);
        debugWrite(", port IS 0x");
        debugWriteHex64(identity.completion_port_status);
        debugWrite("\r\n");
    } else {
        debugWrite("AHCI MSI unavailable; bounded command polling retained\r\n");
    }
    const sector_zero = ahci.readOneSector(controller, identity, 0) orelse
        ahciFailure("READ DMA EXT for LBA 0 did not complete successfully");
    debugWrite("READ DMA EXT completed: LBA ");
    debugWriteU64Decimal(sector_zero.lba);
    debugWrite(", ");
    debugWriteU64Decimal(sector_zero.byte_count);
    debugWrite(" bytes at 0x");
    debugWriteHex64(@intCast(sector_zero.buffer_address));
    debugWrite("\r\n");
    if (identity.msi_enabled) {
        if (sector_zero.completion_interrupt_count != 1) {
            ahciFailure("READ DMA EXT did not complete through exactly one MSI interrupt");
        }
        debugWrite("AHCI READ DMA MSI completion verified: vector 0x");
        debugWriteHex8(identity.interrupt_vector);
        debugWrite(", target APIC ");
        debugWriteU64Decimal(identity.interrupt_target_apic_id);
        debugWrite(", interrupt count ");
        debugWriteU64Decimal(sector_zero.completion_interrupt_count);
        debugWrite(", global IS 0x");
        debugWriteHex64(sector_zero.completion_global_status);
        debugWrite(", port IS 0x");
        debugWriteHex64(sector_zero.completion_port_status);
        debugWrite("\r\n");
    }
    debugWrite("LBA 0 first 16 bytes:");
    for (sector_zero.first_bytes) |byte| {
        debugWrite(" ");
        debugWriteHex8(byte);
    }
    debugWrite("\r\n");
    inspectPartitionAndFat(controller, identity, sector_zero);
    debugWrite("LBA 0 FNV-1a64: 0x");
    debugWriteHex64(sector_zero.fnv1a64);
    debugWrite(", trailing signature 0x");
    debugWriteHex16(sector_zero.trailing_signature);
    debugWrite("\r\n");
    return true;
}

fn inspectPartitionAndFat(
    controller: ahci.Controller,
    identity: ahci.IdentifyResult,
    sector_zero: ahci.ReadResult,
) void {
    const mbr = partition.parseMbr(ahci.readBuffer(sector_zero)) orelse
        filesystemFailure("LBA 0 did not contain a valid MBR");
    debugWrite("MBR parsed: disk signature 0x");
    debugWriteHex64(mbr.disk_signature);
    debugWrite(", populated partitions ");
    debugWriteU64Decimal(mbr.populated_count);
    debugWrite("\r\n");

    for (mbr.partitions) |entry| {
        if (entry.partition_type == 0 or entry.sector_count == 0) continue;
        debugWrite("MBR partition ");
        debugWriteU64Decimal(entry.index);
        debugWrite(if (entry.bootable) " bootable" else " non-bootable");
        debugWrite(", type 0x");
        debugWriteHex8(entry.partition_type);
        debugWrite(", LBA ");
        debugWriteU64Decimal(entry.first_lba);
        debugWrite(" + ");
        debugWriteU64Decimal(entry.sector_count);
        debugWrite(" sectors\r\n");
    }

    const selected = partition.firstUsablePartition(mbr) orelse
        filesystemFailure("MBR contained no usable partition");
    const partition_end = @as(u64, selected.first_lba) + selected.sector_count;
    if (partition_end > identity.sector_count) {
        filesystemFailure("partition extends beyond IDENTIFY-reported device capacity");
    }

    const boot_sector = ahci.readOneSector(controller, identity, selected.first_lba) orelse
        filesystemFailure("partition volume boot sector read failed");
    const volume = fat.parseBootSector(ahci.readBuffer(boot_sector), selected.first_lba) orelse
        filesystemFailure("volume boot sector was not a valid FAT BPB");

    debugWrite("FAT volume detected: ");
    debugWrite(switch (volume.kind) {
        .fat12 => "FAT12",
        .fat16 => "FAT16",
        .fat32 => "FAT32",
    });
    debugWrite(", label \"");
    debugWrite(fat.terminatedSlice(&volume.volume_label));
    debugWrite("\", fs label \"");
    debugWrite(fat.terminatedSlice(&volume.filesystem_label));
    debugWrite("\", volume ID 0x");
    debugWriteHex64(volume.volume_id);
    debugWrite("\r\n");
    debugWrite("FAT geometry: ");
    debugWriteU64Decimal(volume.bytes_per_sector);
    debugWrite(" bytes/sector, ");
    debugWriteU64Decimal(volume.sectors_per_cluster);
    debugWrite(" sectors/cluster, ");
    debugWriteU64Decimal(volume.fat_count);
    debugWrite(" FAT(s) x ");
    debugWriteU64Decimal(volume.sectors_per_fat);
    debugWrite(" sectors\r\n");
    debugWrite("FAT layout: first FAT LBA ");
    debugWriteU64Decimal(volume.first_fat_lba);
    debugWrite(", first data LBA ");
    debugWriteU64Decimal(volume.first_data_lba);
    debugWrite(", root directory LBA ");
    debugWriteU64Decimal(volume.root_directory_lba);
    debugWrite(", clusters ");
    debugWriteU64Decimal(volume.cluster_count);
    debugWrite("\r\n");
    walkFatBootPath(controller, identity, volume);
}

fn walkFatBootPath(controller: ahci.Controller, identity: ahci.IdentifyResult, volume: fat.Volume) void {
    const efi_entry = findRootDirectoryEntry(controller, identity, volume, "EFI") orelse
        filesystemFailure("FAT root directory did not contain EFI");
    if (!efi_entry.isDirectory() or efi_entry.first_cluster < 2) {
        filesystemFailure("EFI root entry was not a valid directory");
    }

    const boot_entry = findClusterDirectoryEntry(
        controller,
        identity,
        volume,
        efi_entry.first_cluster,
        "BOOT",
    ) orelse filesystemFailure("EFI directory did not contain BOOT");
    if (!boot_entry.isDirectory() or boot_entry.first_cluster < 2) {
        filesystemFailure("EFI/BOOT entry was not a valid directory");
    }

    const loader_entry = findClusterDirectoryEntry(
        controller,
        identity,
        volume,
        boot_entry.first_cluster,
        "BOOTX64.EFI",
    ) orelse filesystemFailure("EFI/BOOT did not contain BOOTX64.EFI");
    if (loader_entry.isDirectory() or loader_entry.first_cluster < 2 or loader_entry.file_size == 0) {
        filesystemFailure("BOOTX64.EFI entry did not describe a non-empty file");
    }

    debugWrite("FAT path resolved: EFI cluster ");
    debugWriteU64Decimal(efi_entry.first_cluster);
    debugWrite(" -> BOOT cluster ");
    debugWriteU64Decimal(boot_entry.first_cluster);
    debugWrite(" -> BOOTX64.EFI cluster ");
    debugWriteU64Decimal(loader_entry.first_cluster);
    debugWrite("\r\n");
    debugWrite("FAT boot file found: EFI/BOOT/BOOTX64.EFI, size ");
    debugWriteU64Decimal(loader_entry.file_size);
    debugWrite(" bytes\r\n");
    validateStreamedBootFile(controller, identity, volume, loader_entry);
}

const FatFileStream = struct {
    byte_count: u64,
    cluster_count: u32,
    last_cluster: u32,
    fnv1a64: u64,
    first_sector: [512]u8,
};

fn validateStreamedBootFile(
    controller: ahci.Controller,
    identity: ahci.IdentifyResult,
    volume: fat.Volume,
    entry: fat.DirectoryEntry,
) void {
    const stream = streamFatFile(controller, identity, volume, entry);
    const image = pe.parse(&stream.first_sector) orelse
        filesystemFailure("streamed BOOTX64.EFI did not contain valid DOS/PE headers");
    if (!image.amd64 or !image.pe32_plus or !image.efi_application) {
        filesystemFailure("streamed BOOTX64.EFI was not an AMD64 PE32+ EFI application");
    }
    if (image.size_of_headers > stream.byte_count or image.size_of_image == 0) {
        filesystemFailure("streamed PE image reported invalid image/header sizes");
    }

    debugWrite("FAT file streamed: ");
    debugWriteU64Decimal(stream.byte_count);
    debugWrite(" bytes across ");
    debugWriteU64Decimal(stream.cluster_count);
    debugWrite(" cluster(s), last cluster ");
    debugWriteU64Decimal(stream.last_cluster);
    debugWrite(", FNV-1a64 0x");
    debugWriteHex64(stream.fnv1a64);
    debugWrite("\r\n");
    debugWrite("On-disk PE verified: AMD64 PE32+, EFI subsystem ");
    debugWriteU64Decimal(image.subsystem);
    debugWrite(", sections ");
    debugWriteU64Decimal(image.section_count);
    debugWrite(", entry RVA 0x");
    debugWriteHex64(image.entry_point_rva);
    debugWrite(", image base 0x");
    debugWriteHex64(image.image_base);
    debugWrite(", image size ");
    debugWriteU64Decimal(image.size_of_image);
    debugWrite("\r\n");
}

fn streamFatFile(
    controller: ahci.Controller,
    identity: ahci.IdentifyResult,
    volume: fat.Volume,
    entry: fat.DirectoryEntry,
) FatFileStream {
    if (entry.isDirectory() or entry.first_cluster < 2 or entry.file_size == 0) {
        filesystemFailure("FAT file stream received an invalid file entry");
    }

    var result = FatFileStream{
        .byte_count = 0,
        .cluster_count = 0,
        .last_cluster = 0,
        .fnv1a64 = 0xCBF2_9CE4_8422_2325,
        .first_sector = undefined,
    };
    var remaining: u64 = entry.file_size;
    var cluster = entry.first_cluster;
    var first_sector_copied = false;

    while (remaining != 0 and result.cluster_count < 1_000_000) {
        const first_lba = fat.clusterFirstLba(volume, cluster) orelse
            filesystemFailure("file cluster was outside FAT data range");
        result.cluster_count += 1;
        result.last_cluster = cluster;

        var sector_index: u8 = 0;
        while (sector_index < volume.sectors_per_cluster and remaining != 0) : (sector_index += 1) {
            const sector = ahci.readOneSector(controller, identity, first_lba + sector_index) orelse
                filesystemFailure("FAT file sector read failed");
            const sector_bytes = ahci.readBuffer(sector);
            const take: usize = @intCast(@min(remaining, sector_bytes.len));
            if (!first_sector_copied) {
                if (sector_bytes.len < result.first_sector.len) {
                    filesystemFailure("first FAT file sector was smaller than 512 bytes");
                }
                @memcpy(&result.first_sector, sector_bytes[0..result.first_sector.len]);
                first_sector_copied = true;
            }
            result.fnv1a64 = fnv1aUpdate(result.fnv1a64, sector_bytes[0..take]);
            result.byte_count += take;
            remaining -= take;
        }

        const link = readFatClusterLink(controller, identity, volume, cluster);
        if (remaining == 0) {
            switch (link) {
                .end => {},
                else => filesystemFailure("file data ended before the FAT cluster chain"),
            }
            break;
        }
        switch (link) {
            .next => |next_cluster| cluster = next_cluster,
            .end => filesystemFailure("FAT cluster chain ended before the declared file size"),
            .free => filesystemFailure("FAT file cluster chain reached a free entry"),
            .bad => filesystemFailure("FAT file cluster chain reached a bad cluster"),
        }
    }

    if (remaining != 0 or result.byte_count != entry.file_size or !first_sector_copied) {
        filesystemFailure("FAT file stream did not consume the declared file size");
    }
    return result;
}

fn readFatClusterLink(
    controller: ahci.Controller,
    identity: ahci.IdentifyResult,
    volume: fat.Volume,
    cluster: u32,
) fat.ClusterLink {
    const location = fat.fatEntryLocation(volume, cluster) orelse
        filesystemFailure("FAT cluster entry location was invalid");
    const fat_sector = ahci.readOneSector(controller, identity, location.lba) orelse
        filesystemFailure("FAT cluster-link sector read failed");
    return fat.decodeClusterLink(volume, cluster, ahci.readBuffer(fat_sector)) orelse
        filesystemFailure("FAT cluster-link value was invalid");
}

fn fnv1aUpdate(initial_hash: u64, bytes: []const u8) u64 {
    var hash = initial_hash;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x0000_0100_0000_01B3;
    }
    return hash;
}

fn findRootDirectoryEntry(
    controller: ahci.Controller,
    identity: ahci.IdentifyResult,
    volume: fat.Volume,
    expected_name: []const u8,
) ?fat.DirectoryEntry {
    if (volume.kind == .fat32) {
        return findClusterDirectoryEntry(controller, identity, volume, volume.root_cluster, expected_name);
    }

    var sector_index: u32 = 0;
    while (sector_index < volume.root_directory_sectors) : (sector_index += 1) {
        const sector = ahci.readOneSector(controller, identity, volume.root_directory_lba + sector_index) orelse
            filesystemFailure("FAT root-directory sector read failed");
        const directory = fat.parseDirectorySector(ahci.readBuffer(sector)) orelse
            filesystemFailure("FAT root-directory entry decoding failed");
        printDirectoryEntries("FAT root", directory);
        if (findNamedEntry(directory, expected_name)) |entry| return entry;
        if (directory.end_of_directory) return null;
    }
    return null;
}

fn findClusterDirectoryEntry(
    controller: ahci.Controller,
    identity: ahci.IdentifyResult,
    volume: fat.Volume,
    initial_cluster: u32,
    expected_name: []const u8,
) ?fat.DirectoryEntry {
    var cluster = initial_cluster;
    var traversed_clusters: usize = 0;
    while (traversed_clusters < 4096) : (traversed_clusters += 1) {
        const first_lba = fat.clusterFirstLba(volume, cluster) orelse
            filesystemFailure("directory cluster was outside FAT data range");

        var sector_index: u8 = 0;
        while (sector_index < volume.sectors_per_cluster) : (sector_index += 1) {
            const sector = ahci.readOneSector(controller, identity, first_lba + sector_index) orelse
                filesystemFailure("FAT directory-cluster sector read failed");
            const directory = fat.parseDirectorySector(ahci.readBuffer(sector)) orelse
                filesystemFailure("FAT directory-cluster entry decoding failed");
            if (findNamedEntry(directory, expected_name)) |entry| return entry;
            if (directory.end_of_directory) return null;
        }

        const location = fat.fatEntryLocation(volume, cluster) orelse
            filesystemFailure("FAT cluster entry location was invalid");
        const fat_sector = ahci.readOneSector(controller, identity, location.lba) orelse
            filesystemFailure("FAT cluster-link sector read failed");
        const link = fat.decodeClusterLink(volume, cluster, ahci.readBuffer(fat_sector)) orelse
            filesystemFailure("FAT cluster-link value was invalid");
        switch (link) {
            .next => |next_cluster| cluster = next_cluster,
            .end => return null,
            .free => filesystemFailure("directory cluster chain reached a free entry"),
            .bad => filesystemFailure("directory cluster chain reached a bad cluster"),
        }
    }
    filesystemFailure("directory cluster chain exceeded traversal limit");
}

fn findNamedEntry(directory: fat.DirectorySector, expected_name: []const u8) ?fat.DirectoryEntry {
    for (directory.entries[0..directory.count]) |entry| {
        if (fat.namesEqual(entry.nameSlice(), expected_name)) return entry;
    }
    return null;
}

fn printDirectoryEntries(prefix: []const u8, directory: fat.DirectorySector) void {
    for (directory.entries[0..directory.count]) |entry| {
        debugWrite(prefix);
        debugWrite(" entry: ");
        debugWrite(entry.nameSlice());
        debugWrite(if (entry.isDirectory()) " <DIR> cluster " else " file cluster ");
        debugWriteU64Decimal(entry.first_cluster);
        debugWrite(", size ");
        debugWriteU64Decimal(entry.file_size);
        debugWrite("\r\n");
    }
}

fn storageFailure(reason: []const u8) noreturn {
    debugWrite("Storage discovery failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn filesystemFailure(reason: []const u8) noreturn {
    debugWrite("Filesystem discovery failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn ahciDeviceTypeName(device_type: ahci.DeviceType) []const u8 {
    return switch (device_type) {
        .none => "no device",
        .sata => "SATA",
        .satapi => "SATAPI",
        .enclosure_management => "SEMB",
        .port_multiplier => "port multiplier",
        .unknown => "unknown device",
    };
}

fn ahciFailure(reason: []const u8) noreturn {
    debugWrite("AHCI discovery failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn testCooperativeScheduler(allocator: *memory.FrameAllocator) void {
    cooperative_trace = @splat(0);
    cooperative_trace_length = 0;
    cooperative_task_a_count = 0;
    cooperative_task_b_count = 0;

    const report = scheduler.runTwo(allocator, &cooperativeTaskA, &cooperativeTaskB) orelse
        schedulerFailure("task creation or context return failed");
    if (report.task_count != 2 or !report.first.finished or !report.second.finished) {
        schedulerFailure("both cooperative tasks did not reach the finished state");
    }
    if (!report.first.canary_intact or !report.second.canary_intact) {
        schedulerFailure("a task stack canary was overwritten");
    }
    if (cooperative_task_a_count != 5 or cooperative_task_b_count != 7) {
        schedulerFailure("task counters did not reach their deterministic totals");
    }
    if (report.first.yields != 5 or report.second.yields != 7) {
        schedulerFailure("per-task yield counters were incorrect");
    }
    const expected_trace = "ABABABABABBB";
    if (cooperative_trace_length != expected_trace.len or
        !std.mem.eql(u8, cooperative_trace[0..cooperative_trace_length], expected_trace))
    {
        schedulerFailure("cooperative task interleave was not deterministic");
    }
    if (report.context_switches != 13) {
        schedulerFailure("unexpected cooperative context-switch count");
    }

    debugWrite("Cooperative scheduler active: 2 tasks, ");
    debugWriteU64Decimal(report.context_switches);
    debugWrite(" context switches, trace ");
    debugWrite(cooperative_trace[0..cooperative_trace_length]);
    debugWrite("\r\n");
    debugWrite("Task A: stack 0x");
    debugWriteHex64(@intCast(report.first.stack_base));
    debugWrite(" + ");
    debugWriteUsizeDecimal(report.first.stack_size);
    debugWrite(" bytes, yields ");
    debugWriteU64Decimal(report.first.yields);
    debugWrite("; Task B: stack 0x");
    debugWriteHex64(@intCast(report.second.stack_base));
    debugWrite(" + ");
    debugWriteUsizeDecimal(report.second.stack_size);
    debugWrite(" bytes, yields ");
    debugWriteU64Decimal(report.second.yields);
    debugWrite("\r\n");
    debugWrite("Scheduler stack canaries intact; execution returned to the kernel context.\r\n");
}

fn cooperativeTaskA() callconv(cc) void {
    var iteration: u8 = 0;
    while (iteration < 5) : (iteration += 1) {
        cooperative_task_a_count += 1;
        appendCooperativeTrace('A');
        scheduler.yield();
    }
}

fn cooperativeTaskB() callconv(cc) void {
    var iteration: u8 = 0;
    while (iteration < 7) : (iteration += 1) {
        cooperative_task_b_count += 1;
        appendCooperativeTrace('B');
        scheduler.yield();
    }
}

fn appendCooperativeTrace(marker: u8) void {
    if (cooperative_trace_length >= cooperative_trace.len) {
        schedulerFailure("cooperative trace overflow");
    }
    cooperative_trace[cooperative_trace_length] = marker;
    cooperative_trace_length += 1;
}

fn schedulerFailure(reason: []const u8) noreturn {
    debugWrite("Scheduler verification failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn testPreemptiveScheduler(allocator: *memory.FrameAllocator, ticks_per_second: u64) void {
    preemptive_task_a_iterations = 0;
    preemptive_task_b_iterations = 0;

    const report = preemptive.runTwo(
        allocator,
        &preemptiveTaskA,
        &preemptiveTaskB,
        ticks_per_second,
        200,
    ) orelse preemptiveFailure("task launch, timer setup, or kernel-context return failed");

    if (!report.first.finished or !report.second.finished) {
        preemptiveFailure("both timer-preempted tasks did not finish");
    }
    if (!report.first.canary_intact or !report.second.canary_intact) {
        preemptiveFailure("a preemptive task stack canary was overwritten");
    }
    if (report.timer_ticks < 8 or report.timer_preemptions < 8) {
        preemptiveFailure("the APIC timer did not perform enough task preemptions");
    }
    if (report.first.preemptions == 0 or report.second.preemptions == 0) {
        preemptiveFailure("both CPU-bound tasks were not independently preempted");
    }
    if (volatileCounter(&preemptive_task_a_iterations) == 0 or
        volatileCounter(&preemptive_task_b_iterations) == 0)
    {
        preemptiveFailure("a CPU-bound task never executed its work loop");
    }

    debugWrite("Preemptive scheduler active: APIC periodic count ");
    debugWriteU64Decimal(report.periodic_initial_count);
    debugWrite(", timer ticks ");
    debugWriteU64Decimal(report.timer_ticks);
    debugWrite(", preemptions ");
    debugWriteU64Decimal(report.timer_preemptions);
    debugWrite(", total context switches ");
    debugWriteU64Decimal(report.context_switches);
    debugWrite("\r\n");
    debugWrite("CPU-bound task A iterations ");
    debugWriteU64Decimal(volatileCounter(&preemptive_task_a_iterations));
    debugWrite(", task B iterations ");
    debugWriteU64Decimal(volatileCounter(&preemptive_task_b_iterations));
    debugWrite("\r\n");
    debugWrite("Timer-frame GPR/FX state switching verified; no task called yield.\r\n");
    debugWrite("Preemptive stack canaries intact; kernel interrupt frame restored.\r\n");
}

fn preemptiveTaskA() callconv(cc) void {
    while (preemptive.tickCount() < 8) {
        incrementVolatileCounter(&preemptive_task_a_iterations);
        preemptive.relax();
    }
}

fn preemptiveTaskB() callconv(cc) void {
    while (preemptive.tickCount() < 8) {
        incrementVolatileCounter(&preemptive_task_b_iterations);
        preemptive.relax();
    }
}

fn incrementVolatileCounter(counter: *u64) void {
    const pointer: *volatile u64 = @ptrCast(counter);
    pointer.* +%= 1;
}

fn volatileCounter(counter: *const u64) u64 {
    const pointer: *const volatile u64 = @ptrCast(counter);
    return pointer.*;
}

fn preemptiveFailure(reason: []const u8) noreturn {
    debugWrite("Preemptive scheduler failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn testUserMode(allocator: *memory.FrameAllocator) void {
    const report = user_mode.run(allocator) orelse
        userModeFailure("CPL3 entry, syscall return, or kernel restoration failed");
    if (!report.returned_to_kernel or !report.stack_canary_intact) {
        userModeFailure("userspace did not return with an intact isolated stack");
    }
    if (report.observed_cs != descriptor_tables.user_code_selector or
        report.observed_ss != descriptor_tables.user_data_selector)
    {
        userModeFailure("syscall frame did not contain the expected RPL3 selectors");
    }
    if (report.syscall_count != 2 or report.exit_code != 0x42) {
        userModeFailure("userspace syscall count or exit code was incorrect");
    }

    debugWrite("CPL3 userspace active: code physical 0x");
    debugWriteHex64(@intCast(report.code_physical));
    debugWrite(" -> virtual 0x");
    debugWriteHex64(@intCast(report.code_virtual));
    debugWrite(", stack physical 0x");
    debugWriteHex64(@intCast(report.stack_physical));
    debugWrite(" -> virtual 0x");
    debugWriteHex64(@intCast(report.stack_virtual));
    debugWrite("\r\n");
    debugWrite("User page-table isolation: ");
    debugWriteU64Decimal(report.page_table_pages);
    debugWrite(" dedicated tables, payload ");
    debugWriteUsizeDecimal(report.program_size);
    debugWrite(" bytes\r\n");
    debugWrite("int 0x80 syscall frame verified: CS=0x");
    debugWriteHex16(@truncate(report.observed_cs));
    debugWrite(", SS=0x");
    debugWriteHex16(@truncate(report.observed_ss));
    debugWrite(", RIP=0x");
    debugWriteHex64(report.observed_rip);
    debugWrite(", RSP=0x");
    debugWriteHex64(report.observed_rsp);
    debugWrite("\r\n");
    debugWrite("Userspace report argument 0x");
    debugWriteHex64(report.observed_argument);
    debugWrite(", syscall count ");
    debugWriteU64Decimal(report.syscall_count);
    debugWrite(", exit code 0x");
    debugWriteHex64(report.exit_code);
    debugWrite("\r\n");
    debugWrite("CPL3 -> kernel -> CPL3 -> kernel round trip complete; stack canary intact.\r\n");
}

fn userModeFailure(reason: []const u8) noreturn {
    debugWrite("Userspace verification failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn framebufferConsoleFailure(reason: []const u8) noreturn {
    debugWrite("Framebuffer console failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn debugWrite(text: []const u8) void {
    for (text) |character| {
        zigos_debug_putc(character);
        _ = serial.putByte(character);
    }
}

fn debugWriteIpv4(address: [4]u8) void {
    for (address, 0..) |octet, index| {
        if (index != 0) debugWrite(".");
        debugWriteU64Decimal(octet);
    }
}

fn debugWriteHex8(value: u8) void {
    const digits = "0123456789ABCDEF";
    const text = [2]u8{
        digits[@as(u4, @truncate(value >> 4))],
        digits[@as(u4, @truncate(value))],
    };
    debugWrite(&text);
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
        debugWrite("0");
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
