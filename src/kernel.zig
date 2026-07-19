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
const ntp = @import("ntp.zig");
const tftp = @import("tftp.zig");
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
    continuous_counter: time_reference.ContinuousCounter,
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
    var timer_setup = testApicTimer(acpi_info);
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
        &timer_setup.continuous_counter,
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
    const reference = time_reference.Reference.initialize(discovery.hpet_address, discovery.facp_address) orelse
        timerFailure("neither HPET, ACPI PM timer, nor PIT channel 2 could provide a reference clock");

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
        .acpi_pm_timer => {
            debugWrite("ACPI PM timer active: address 0x");
            debugWriteHex64(@intCast(reference.baseAddress()));
            debugWrite(", ");
            debugWrite(reference.addressSpaceName());
            debugWrite(", frequency ");
            debugWriteU64Decimal(reference.continuousFrequencyHz().?);
            debugWrite(" Hz, ");
            debugWriteU64Decimal(reference.counterBits());
            debugWrite("-bit counter\r\n");
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

    var continuous_counter = time_reference.ContinuousCounter.initialize(reference) orelse
        timerFailure("the selected calibration source did not expose a continuous counter");
    const first_counter = continuous_counter.read();
    if (!reference.waitNanoseconds(1_000_000))
        timerFailure("the continuous reference counter delay failed");
    const second_counter = continuous_counter.read();
    if (second_counter <= first_counter)
        timerFailure("the continuous reference counter did not advance");
    debugWrite("Continuous reference counter: source ");
    debugWrite(reference.sourceName());
    debugWrite(", frequency ");
    debugWriteU64Decimal(continuous_counter.frequency_hz);
    debugWrite(" Hz, bits ");
    debugWriteU64Decimal(continuous_counter.counter_bits);
    debugWrite(", first/second/delta ");
    debugWriteU64Decimal(first_counter);
    debugWrite("/");
    debugWriteU64Decimal(second_counter);
    debugWrite("/");
    debugWriteU64Decimal(second_counter - first_counter);
    debugWrite("\r\n");
    return .{
        .result = result,
        .reference = reference,
        .continuous_counter = continuous_counter,
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
    continuous_counter: *time_reference.ContinuousCounter,
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
        continuous_counter,
    ) orelse networkFailure("reset, DMA rings, MSI-X, DHCP, ARP, ICMP, UDP, or TFTP validation failed");

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

    debugWrite("e1000e DHCP Discover transmitted: xid 0x");
    debugWriteHex64(network.dhcp_transaction_id);
    debugWrite(", ");
    debugWriteU64Decimal(network.dhcp_discover_length);
    debugWrite(" bytes, TX interrupts ");
    debugWriteU64Decimal(network.dhcp_discover_tx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.dhcp_discover_tx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e DHCP Offer received: address ");
    debugWriteIpv4(network.dhcp_offer_address);
    debugWrite(", server ");
    debugWriteIpv4(network.dhcp_offer_server_identifier);
    debugWrite(", lease ");
    debugWriteU64Decimal(network.dhcp_offer_lease_seconds);
    debugWrite(" s, ");
    debugWriteU64Decimal(network.dhcp_offer_length);
    debugWrite(" bytes, RX interrupts ");
    debugWriteU64Decimal(network.dhcp_offer_rx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.dhcp_offer_rx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e DHCP Request transmitted: address ");
    debugWriteIpv4(network.dhcp_offer_address);
    debugWrite(", server ");
    debugWriteIpv4(network.dhcp_offer_server_identifier);
    debugWrite(", ");
    debugWriteU64Decimal(network.dhcp_request_length);
    debugWrite(" bytes, TX interrupts ");
    debugWriteU64Decimal(network.dhcp_request_tx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.dhcp_request_tx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e DHCP ACK received: address ");
    debugWriteIpv4(network.dhcp_address);
    debugWrite(", subnet ");
    debugWriteIpv4(network.dhcp_subnet_mask);
    debugWrite(", router ");
    debugWriteIpv4(network.dhcp_router);
    debugWrite(if (network.dhcp_router_advertised) " (advertised)" else " (server fallback)");
    debugWrite(", DNS ");
    if (network.dhcp_dns_server_advertised) {
        debugWriteIpv4(network.dhcp_dns_server);
    } else {
        debugWrite("absent");
    }
    debugWrite(", server ");
    debugWriteIpv4(network.dhcp_server_identifier);
    debugWrite(", lease ");
    debugWriteU64Decimal(network.dhcp_lease_seconds);
    debugWrite(" s, TTL ");
    debugWriteU64Decimal(network.dhcp_reply_ttl);
    debugWrite(", UDP checksum ");
    debugWrite(if (network.dhcp_udp_checksum_present) "present" else "absent");
    debugWrite(", ");
    debugWriteU64Decimal(network.dhcp_ack_length);
    debugWrite(" bytes, RX interrupts ");
    debugWriteU64Decimal(network.dhcp_ack_rx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.dhcp_ack_rx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e ARP request transmitted: ");
    debugWriteIpv4(network.dhcp_address);
    debugWrite(" -> ");
    debugWriteIpv4(network.dhcp_router);
    debugWrite(", ");
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

    debugWrite("e1000e ICMP echo request transmitted: ");
    debugWriteIpv4(network.dhcp_address);
    debugWrite(" -> ");
    debugWriteIpv4(network.dhcp_router);
    debugWrite(", ");
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

    debugWrite("e1000e ICMP echo reply received: ");
    debugWriteIpv4(network.dhcp_router);
    debugWrite(" -> ");
    debugWriteIpv4(network.dhcp_address);
    debugWrite(", ");
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

    debugWrite("e1000e TFTP RRQ transmitted: ");
    debugWrite(tftp.file_name);
    debugWrite(" mode ");
    debugWrite(tftp.mode);
    debugWrite(", ");
    debugWriteU64Decimal(network.tftp_rrq_length);
    debugWrite(" bytes, UDP ");
    debugWriteU64Decimal(tftp.client_port);
    debugWrite(" -> ");
    debugWriteU64Decimal(tftp.server_port);
    debugWrite(", TX interrupts ");
    debugWriteU64Decimal(network.tftp_rrq_tx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.tftp_rrq_tx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e TFTP stream received: blocks ");
    debugWriteU64Decimal(network.tftp_block_count);
    debugWrite(", payload ");
    debugWriteU64Decimal(network.tftp_payload_length);
    debugWrite(" bytes, FNV-1a64 0x");
    debugWriteHex64(network.tftp_payload_fnv1a64);
    debugWrite(", frames ");
    for (network.tftp_data_frame_lengths, 0..) |length, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(length);
    }
    debugWrite(", server port ");
    debugWriteU64Decimal(network.tftp_server_port);
    debugWrite(", TTL ");
    debugWriteU64Decimal(network.tftp_reply_ttl);
    debugWrite(", UDP checksum ");
    debugWrite(if (network.tftp_udp_checksum_present) "present" else "absent");
    debugWrite(", final ");
    debugWrite(if (network.tftp_final_block) "yes" else "no");
    debugWrite(", RX interrupts ");
    debugWriteU64Decimal(network.tftp_data_rx_interrupt_count);
    debugWrite(", cause 0x");
    debugWriteHex64(network.tftp_data_rx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e TFTP ACK stream transmitted: blocks 1-");
    debugWriteU64Decimal(network.tftp_block_count);
    debugWrite(", frames ");
    for (network.tftp_ack_lengths, 0..) |length, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(length);
    }
    debugWrite(", UDP ");
    debugWriteU64Decimal(tftp.client_port);
    debugWrite(" -> ");
    debugWriteU64Decimal(network.tftp_server_port);
    debugWrite(", TX interrupts ");
    debugWriteU64Decimal(network.tftp_ack_tx_interrupt_count);
    debugWrite(", wraps ");
    debugWriteU64Decimal(network.tftp_tx_wrap_count);
    debugWrite(", tail ");
    debugWriteU64Decimal(network.tftp_tx_tail_after_ack);
    debugWrite(", cause 0x");
    debugWriteHex64(network.tftp_ack_tx_interrupt_cause);
    debugWrite("\r\n");

    debugWrite("e1000e RX ring recycled: descriptors ");
    debugWriteU64Decimal(network.rx_recycled_descriptors);
    debugWrite(", wraps ");
    debugWriteU64Decimal(network.rx_descriptor_wrap_count);
    debugWrite(", head ");
    debugWriteU64Decimal(network.rx_head_after_stream);
    debugWrite(", tail ");
    debugWriteU64Decimal(network.rx_tail_after_stream);
    debugWrite("\r\n");

    debugWrite("e1000e completion queues active: TX ");
    debugWriteU64Decimal(network.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.tx_completion_dequeues);
    debugWrite(", RX ");
    debugWriteU64Decimal(network.rx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.rx_completion_dequeues);
    debugWrite(", high-water ");
    debugWriteU64Decimal(network.tx_completion_high_water);
    debugWrite("/");
    debugWriteU64Decimal(network.rx_completion_high_water);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.completion_queue_overflows);
    debugWrite(", pending TX 0x");
    debugWriteHex64(network.tx_pending_mask_after_stream);
    debugWrite(", RX 0x");
    debugWriteHex64(network.rx_pending_mask_after_stream);
    debugWrite("\r\n");

    debugWrite("e1000e persistent queue owner verified: TX descriptor ");
    debugWriteU64Decimal(network.persistent.tx.descriptor_index);
    debugWrite(" -> cursor ");
    debugWriteU64Decimal(network.persistent.tx.next_cursor);
    debugWrite(", RX descriptor ");
    debugWriteU64Decimal(network.persistent.rx_descriptor_index);
    debugWrite(" -> cursor ");
    debugWriteU64Decimal(network.persistent.rx_next_cursor);
    debugWrite(", ICMP 0x");
    debugWriteHex16(network.persistent.identifier);
    debugWrite("/");
    debugWriteU64Decimal(network.persistent.sequence);
    debugWrite(", frames ");
    debugWriteU64Decimal(network.persistent.tx.frame_length);
    debugWrite("/");
    debugWriteU64Decimal(network.persistent.rx_frame_length);
    debugWrite(", interrupts ");
    debugWriteU64Decimal(network.persistent.tx.interrupt_count);
    debugWrite("/");
    debugWriteU64Decimal(network.persistent.rx_interrupt_count);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.persistent.tx_submissions);
    debugWrite(", deliveries ");
    debugWriteU64Decimal(network.persistent.rx_deliveries);
    debugWrite(", cursors wrapped ");
    debugWriteU64Decimal(network.persistent.tx_cursor_wraps);
    debugWrite("/");
    debugWriteU64Decimal(network.persistent.rx_cursor_wraps);
    debugWrite(", final queues TX ");
    debugWriteU64Decimal(network.persistent.tx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.persistent.tx_queue_dequeues);
    debugWrite(", RX ");
    debugWriteU64Decimal(network.persistent.rx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.persistent.rx_queue_dequeues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.persistent.queue_overflows);
    debugWrite(", pending TX 0x");
    debugWriteHex64(network.persistent.tx_pending_mask);
    debugWrite(", RX 0x");
    debugWriteHex64(network.persistent.rx_pending_mask);
    debugWrite("\r\n");

    debugWrite("e1000e software RX queue verified: TX descriptor ");
    debugWriteU64Decimal(network.software_packet_queue.tx.descriptor_index);
    debugWrite(" -> cursor ");
    debugWriteU64Decimal(network.software_packet_queue.device_tx_cursor);
    debugWrite(", DMA RX descriptor ");
    debugWriteU64Decimal(network.software_packet_queue.dma_rx_descriptor);
    debugWrite(" recycled -> cursor ");
    debugWriteU64Decimal(network.software_packet_queue.device_rx_cursor);
    debugWrite(", packet ");
    debugWriteU64Decimal(network.software_packet_queue.packet_length);
    debugWrite(" bytes, ICMP 0x");
    debugWriteHex16(network.software_packet_queue.identifier);
    debugWrite("/");
    debugWriteU64Decimal(network.software_packet_queue.sequence);
    debugWrite(", queue ");
    debugWriteU64Decimal(network.software_packet_queue.queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.software_packet_queue.queue_dequeued);
    debugWrite(", high-water ");
    debugWriteU64Decimal(network.software_packet_queue.queue_high_water);
    debugWrite(", dropped ");
    debugWriteU64Decimal(network.software_packet_queue.queue_dropped);
    debugWrite(", final completions TX ");
    debugWriteU64Decimal(network.software_packet_queue.tx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.software_packet_queue.tx_queue_dequeues);
    debugWrite(", RX ");
    debugWriteU64Decimal(network.software_packet_queue.rx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.software_packet_queue.rx_queue_dequeues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.software_packet_queue.completion_queue_overflows);
    debugWrite(", pending TX 0x");
    debugWriteHex64(network.software_packet_queue.tx_pending_mask);
    debugWrite(", RX 0x");
    debugWriteHex64(network.software_packet_queue.rx_pending_mask);
    debugWrite("\r\n");

    debugWrite("e1000e protocol dispatch verified: TX descriptor ");
    debugWriteU64Decimal(network.protocol_dispatch.tx.descriptor_index);
    debugWrite(" -> cursor ");
    debugWriteU64Decimal(network.protocol_dispatch.device_tx_cursor);
    debugWrite(", DMA RX descriptor ");
    debugWriteU64Decimal(network.protocol_dispatch.dma_rx_descriptor);
    debugWrite(" recycled -> cursor ");
    debugWriteU64Decimal(network.protocol_dispatch.device_rx_cursor);
    debugWrite(", ICMP 0x");
    debugWriteHex16(network.protocol_dispatch.identifier);
    debugWrite("/");
    debugWriteU64Decimal(network.protocol_dispatch.sequence);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.protocol_dispatch.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.protocol_dispatch.ingress_dequeued);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.protocol_dispatch.ingress_dropped);
    debugWrite(", dispatch total ");
    debugWriteU64Decimal(network.protocol_dispatch.packets_dispatched);
    debugWrite(" ARP/ICMP/UDP ");
    debugWriteU64Decimal(network.protocol_dispatch.arp_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.protocol_dispatch.icmp_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.protocol_dispatch.udp_dispatched);
    debugWrite(", unknown ");
    debugWriteU64Decimal(network.protocol_dispatch.unknown_dropped);
    debugWrite(", ICMP queue ");
    debugWriteU64Decimal(network.protocol_dispatch.icmp_queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.protocol_dispatch.icmp_queue_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.protocol_dispatch.icmp_queue_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.protocol_dispatch.icmp_queue_dropped);
    debugWrite(", final completions TX ");
    debugWriteU64Decimal(network.protocol_dispatch.tx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.protocol_dispatch.tx_queue_dequeues);
    debugWrite(", RX ");
    debugWriteU64Decimal(network.protocol_dispatch.rx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.protocol_dispatch.rx_queue_dequeues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.protocol_dispatch.completion_queue_overflows);
    debugWrite(", pending TX 0x");
    debugWriteHex64(network.protocol_dispatch.tx_pending_mask);
    debugWrite(", RX 0x");
    debugWriteHex64(network.protocol_dispatch.rx_pending_mask);
    debugWrite("\r\n");

    debugWrite("e1000e UDP/TFTP dispatch verified: RRQ TX descriptor ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.rrq.descriptor_index);
    debugWrite(", DATA RX descriptors ");
    for (network.udp_tftp_dispatch.data_descriptors, 0..) |descriptor, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(descriptor);
    }
    debugWrite(", ACK TX descriptors ");
    for (network.udp_tftp_dispatch.acknowledgement_descriptors, 0..) |descriptor, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(descriptor);
    }
    debugWrite(", blocks ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.block_count);
    debugWrite(", payload ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.payload_length);
    debugWrite(" bytes, FNV-1a64 0x");
    debugWriteHex64(network.udp_tftp_dispatch.payload_fnv1a64);
    debugWrite(", frames ");
    for (network.udp_tftp_dispatch.data_frame_lengths, 0..) |length, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(length);
    }
    debugWrite(", ACKs ");
    for (network.udp_tftp_dispatch.acknowledgement_frame_lengths, 0..) |length, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(length);
    }
    debugWrite(", server port ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.server_port);
    debugWrite(", checksum ");
    debugWrite(if (network.udp_tftp_dispatch.udp_checksum_present) "present" else "absent");
    debugWrite(", final cursors TX/RX ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.device_tx_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_tftp_dispatch.device_rx_cursor);
    debugWrite(", wraps ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.tx_cursor_wraps);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_tftp_dispatch.rx_cursor_wraps);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_tftp_dispatch.ingress_dequeued);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.ingress_dropped);
    debugWrite(", dispatch ARP/ICMP/UDP ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.arp_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_tftp_dispatch.icmp_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_tftp_dispatch.udp_dispatched);
    debugWrite(", UDP queue ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.udp_queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_tftp_dispatch.udp_queue_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.udp_queue_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.udp_queue_dropped);
    debugWrite(", final completions TX ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.tx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_tftp_dispatch.tx_queue_dequeues);
    debugWrite(", RX ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.rx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_tftp_dispatch.rx_queue_dequeues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.udp_tftp_dispatch.completion_queue_overflows);
    debugWrite(", pending TX 0x");
    debugWriteHex64(network.udp_tftp_dispatch.tx_pending_mask);
    debugWrite(", RX 0x");
    debugWriteHex64(network.udp_tftp_dispatch.rx_pending_mask);
    debugWrite("\r\n");

    debugWrite("e1000e UDP endpoint demux verified: endpoints ");
    debugWriteU64Decimal(network.udp_endpoint_demux.registered_endpoints);
    debugWrite(", miss port ");
    debugWriteU64Decimal(network.udp_endpoint_demux.unmatched_port);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_endpoint_demux.unmatched_dropped);
    debugWrite(", TFTP port ");
    debugWriteU64Decimal(network.udp_endpoint_demux.endpoint_port);
    debugWrite(" slot ");
    debugWriteU64Decimal(network.udp_endpoint_demux.endpoint_index);
    debugWrite(", RRQ TX descriptor ");
    debugWriteU64Decimal(network.udp_endpoint_demux.rrq.descriptor_index);
    debugWrite(", DATA RX descriptors ");
    for (network.udp_endpoint_demux.data_descriptors, 0..) |descriptor, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(descriptor);
    }
    debugWrite(", ACK TX descriptors ");
    for (network.udp_endpoint_demux.acknowledgement_descriptors, 0..) |descriptor, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(descriptor);
    }
    debugWrite(", blocks ");
    debugWriteU64Decimal(network.udp_endpoint_demux.block_count);
    debugWrite(", payload ");
    debugWriteU64Decimal(network.udp_endpoint_demux.payload_length);
    debugWrite(" bytes, FNV-1a64 0x");
    debugWriteHex64(network.udp_endpoint_demux.payload_fnv1a64);
    debugWrite(", endpoint queue ");
    debugWriteU64Decimal(network.udp_endpoint_demux.endpoint_queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_demux.endpoint_queue_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.udp_endpoint_demux.endpoint_queue_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_endpoint_demux.endpoint_queue_dropped);
    debugWrite(", final cursors TX/RX ");
    debugWriteU64Decimal(network.udp_endpoint_demux.device_tx_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_demux.device_rx_cursor);
    debugWrite(", wraps ");
    debugWriteU64Decimal(network.udp_endpoint_demux.tx_cursor_wraps);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_demux.rx_cursor_wraps);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_endpoint_demux.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_demux.ingress_dequeued);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_endpoint_demux.ingress_dropped);
    debugWrite(", dispatch ARP/ICMP/UDP ");
    debugWriteU64Decimal(network.udp_endpoint_demux.arp_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_demux.icmp_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_demux.udp_dispatched);
    debugWrite(", completions TX ");
    debugWriteU64Decimal(network.udp_endpoint_demux.tx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_demux.tx_queue_dequeues);
    debugWrite(" RX ");
    debugWriteU64Decimal(network.udp_endpoint_demux.rx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_demux.rx_queue_dequeues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.udp_endpoint_demux.completion_queue_overflows);
    debugWrite(", pending TX 0x");
    debugWriteHex64(network.udp_endpoint_demux.tx_pending_mask);
    debugWrite(", RX 0x");
    debugWriteHex64(network.udp_endpoint_demux.rx_pending_mask);
    debugWrite("\r\n");

    debugWrite("e1000e UDP datagram API verified: structured RX ");
    debugWriteU64Decimal(network.udp_endpoint_demux.structured_receives);
    debugWrite(", connected TX ");
    debugWriteU64Decimal(network.udp_endpoint_demux.connected_sends);
    debugWrite(", peer port ");
    debugWriteU64Decimal(network.udp_endpoint_demux.connected_peer_port);
    debugWrite(" bound ");
    debugWrite(if (network.udp_endpoint_demux.connected_peer_bound) "yes" else "no");
    debugWrite(", payload metadata retained yes");
    debugWrite("\r\n");

    debugWrite("e1000e UDP endpoint lifecycle verified: table ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.table_capacity);
    debugWrite(", usable queue ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.usable_queue_capacity);
    debugWrite(", duplicate slot ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.duplicate_slot);
    debugWrite(", full-table rejection ");
    debugWrite(if (network.udp_endpoint_lifecycle.full_table_rejected) "yes" else "no");
    debugWrite(", queue slot ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.queue_slot);
    debugWrite(" ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.queue_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.queue_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.queue_dropped);
    debugWrite(", busy unregister rejected ");
    debugWrite(if (network.udp_endpoint_lifecycle.busy_unregister_rejected) "yes" else "no");
    debugWrite(", reuse slot ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.reuse_slot);
    debugWrite(", final endpoints ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.final_registered_endpoints);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.ingress_dequeued);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.ingress_dropped);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.udp_dispatched);
    debugWrite(", unmatched ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.unmatched_dropped);
    debugWrite(", completions TX ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.tx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.tx_queue_dequeues);
    debugWrite(" RX ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.rx_queue_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.rx_queue_dequeues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.completion_queue_overflows);
    debugWrite(", pending TX 0x");
    debugWriteHex64(network.udp_endpoint_lifecycle.tx_pending_mask);
    debugWrite(", RX 0x");
    debugWriteHex64(network.udp_endpoint_lifecycle.rx_pending_mask);
    debugWrite("\r\n");

    debugWrite("e1000e UDP socket handles verified: TFTP slot ");
    debugWriteU64Decimal(network.udp_endpoint_demux.endpoint_index);
    debugWrite(" generation ");
    debugWriteU64Decimal(network.udp_endpoint_demux.socket_generation);
    debugWrite(", lifecycle slot ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.queue_slot);
    debugWrite(" generation ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.queue_generation);
    debugWrite(", duplicate handle ");
    debugWrite(if (network.udp_endpoint_lifecycle.duplicate_handle_match) "yes" else "no");
    debugWrite(", reuse slot ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.reuse_slot);
    debugWrite(" generation ");
    debugWriteU64Decimal(network.udp_endpoint_lifecycle.reuse_generation);
    debugWrite(", stale active/receive/send/close rejected ");
    debugWrite(if (network.udp_endpoint_lifecycle.stale_active_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_endpoint_lifecycle.stale_receive_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_endpoint_lifecycle.stale_send_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_endpoint_lifecycle.stale_close_rejected) "yes" else "no");
    debugWrite("\r\n");

    debugWrite("e1000e UDP peer filtering verified: socket slot ");
    debugWriteU64Decimal(network.udp_peer_filter.socket_slot);
    debugWrite(" generation ");
    debugWriteU64Decimal(network.udp_peer_filter.socket_generation);
    debugWrite(", local/peer ports ");
    debugWriteU64Decimal(network.udp_peer_filter.local_port);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peer_filter.peer_port);
    debugWrite(", correct accepted ");
    debugWrite(if (network.udp_peer_filter.correct_peer_accepted) "yes" else "no");
    debugWrite(", wrong MAC/IP/port rejected ");
    debugWrite(if (network.udp_peer_filter.wrong_mac_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_peer_filter.wrong_ipv4_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_peer_filter.wrong_port_rejected) "yes" else "no");
    debugWrite(", invalid checksum rejected ");
    debugWrite(if (network.udp_peer_filter.invalid_checksum_rejected) "yes" else "no");
    debugWrite(", wildcard after disconnect ");
    debugWrite(if (network.udp_peer_filter.wildcard_after_disconnect) "yes" else "no");
    debugWrite(", endpoint queue ");
    debugWriteU64Decimal(network.udp_peer_filter.endpoint_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peer_filter.endpoint_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.udp_peer_filter.endpoint_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_peer_filter.endpoint_dropped);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_peer_filter.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peer_filter.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_peer_filter.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peer_filter.udp_dispatched);
    debugWrite(", drops unmatched/invalid/peer ");
    debugWriteU64Decimal(network.udp_peer_filter.unmatched_dropped);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peer_filter.invalid_udp_dropped);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peer_filter.peer_mismatch_dropped);
    debugWrite(", final endpoints ");
    debugWriteU64Decimal(network.udp_peer_filter.final_registered_endpoints);
    debugWrite("\r\n");

    debugWrite("e1000e UDP ephemeral ports verified: range ");
    debugWriteU64Decimal(network.udp_ephemeral_ports.range_first);
    debugWrite("-");
    debugWriteU64Decimal(network.udp_ephemeral_ports.range_last);
    debugWrite(", first slot/gen/port ");
    debugWriteU64Decimal(network.udp_ephemeral_ports.first_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.first_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.first_port);
    debugWrite(", second ");
    debugWriteU64Decimal(network.udp_ephemeral_ports.second_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.second_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.second_port);
    debugWrite(", full-table rejected ");
    debugWrite(if (network.udp_ephemeral_ports.full_table_rejected) "yes" else "no");
    debugWrite(", collision skipped ");
    debugWrite(if (network.udp_ephemeral_ports.collision_skipped) "yes" else "no");
    debugWrite(" -> ");
    debugWriteU64Decimal(network.udp_ephemeral_ports.collision_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.collision_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.collision_port);
    debugWrite(", wrap ");
    debugWriteU64Decimal(network.udp_ephemeral_ports.wrap_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.wrap_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.wrap_port);
    debugWrite(" -> ");
    debugWriteU64Decimal(network.udp_ephemeral_ports.post_wrap_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.post_wrap_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.post_wrap_port);
    debugWrite(", final cursor/endpoints ");
    debugWriteU64Decimal(network.udp_ephemeral_ports.final_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_ephemeral_ports.final_registered_endpoints);
    debugWrite("\r\n");

    debugWrite("e1000e UDP socket queue verified: slot/gen/port ");
    debugWriteU64Decimal(network.udp_socket_queue.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_socket_queue.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_socket_queue.local_port);
    debugWrite(", connected peer ");
    debugWriteU64Decimal(network.udp_socket_queue.peer_port);
    debugWrite(", pending/readable before ");
    debugWriteU64Decimal(network.udp_socket_queue.pending_before_discard);
    debugWrite("/");
    debugWrite(if (network.udp_socket_queue.readable_before_discard) "yes" else "no");
    debugWrite(", disconnect pending rejected ");
    debugWrite(if (network.udp_socket_queue.disconnect_while_pending_rejected) "yes" else "no");
    debugWrite(", discarded ");
    debugWriteU64Decimal(network.udp_socket_queue.discarded_packets);
    debugWrite(", pending/readable after ");
    debugWriteU64Decimal(network.udp_socket_queue.pending_after_discard);
    debugWrite("/");
    debugWrite(if (network.udp_socket_queue.readable_after_discard) "yes" else "no");
    debugWrite(", queue ");
    debugWriteU64Decimal(network.udp_socket_queue.queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_socket_queue.queue_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.udp_socket_queue.queue_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_socket_queue.queue_dropped);
    debugWrite(", stale status/discard rejected ");
    debugWrite(if (network.udp_socket_queue.stale_status_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_socket_queue.stale_discard_rejected) "yes" else "no");
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_socket_queue.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_socket_queue.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_socket_queue.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_socket_queue.udp_dispatched);
    debugWrite(", final endpoints ");
    debugWriteU64Decimal(network.udp_socket_queue.final_registered_endpoints);
    debugWrite("\r\n");

    debugWrite("e1000e UDP dispatch batch verified: slot/gen/port ");
    debugWriteU64Decimal(network.udp_dispatch_batch.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.local_port);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.udp_dispatch_batch.initial_ingress_depth);
    debugWrite(", batches examined/routed/dropped/remaining ");
    debugWriteU64Decimal(network.udp_dispatch_batch.first_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.first_routed);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.first_dropped);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.first_remaining);
    debugWrite(" -> ");
    debugWriteU64Decimal(network.udp_dispatch_batch.second_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.second_routed);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.second_dropped);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.second_remaining);
    debugWrite(" -> ");
    debugWriteU64Decimal(network.udp_dispatch_batch.final_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.final_routed);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.final_dropped);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.final_remaining);
    debugWrite(", empty ");
    debugWriteU64Decimal(network.udp_dispatch_batch.empty_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.empty_remaining);
    debugWrite(", delivered/high-water ");
    debugWriteU64Decimal(network.udp_dispatch_batch.delivered_datagrams);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.endpoint_high_water);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_dispatch_batch.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_dispatch_batch.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.udp_dispatched);
    debugWrite(", drops unmatched/invalid ");
    debugWriteU64Decimal(network.udp_dispatch_batch.unmatched_dropped);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_dispatch_batch.invalid_udp_dropped);
    debugWrite(", final endpoints ");
    debugWriteU64Decimal(network.udp_dispatch_batch.final_registered_endpoints);
    debugWrite("\r\n");

    debugWrite("e1000e UDP endpoint poll verified: sockets ");
    debugWriteU64Decimal(network.udp_endpoint_poll.first_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.first_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.first_port);
    debugWrite(" and ");
    debugWriteU64Decimal(network.udp_endpoint_poll.second_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.second_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.second_port);
    debugWrite(", initial masks active/readable/connected 0x");
    debugWriteHex8(network.udp_endpoint_poll.initial_active_mask);
    debugWrite("/0x");
    debugWriteHex8(network.udp_endpoint_poll.initial_readable_mask);
    debugWrite("/0x");
    debugWriteHex8(network.udp_endpoint_poll.initial_connected_mask);
    debugWrite(", pending/max ");
    debugWriteU64Decimal(network.udp_endpoint_poll.initial_total_pending);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.initial_max_pending);
    debugWrite(", partial readable/pending 0x");
    debugWriteHex8(network.udp_endpoint_poll.partial_readable_mask);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.partial_total_pending);
    debugWrite(", drained readable/pending 0x");
    debugWriteHex8(network.udp_endpoint_poll.drained_readable_mask);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.drained_total_pending);
    debugWrite(", final masks active/readable/connected 0x");
    debugWriteHex8(network.udp_endpoint_poll.final_active_mask);
    debugWrite("/0x");
    debugWriteHex8(network.udp_endpoint_poll.final_readable_mask);
    debugWrite("/0x");
    debugWriteHex8(network.udp_endpoint_poll.final_connected_mask);
    debugWrite(", pending/endpoints/cursor ");
    debugWriteU64Decimal(network.udp_endpoint_poll.final_total_pending);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_endpoint_poll.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_endpoint_poll.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_endpoint_poll.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("e1000e UDP service cycle verified: sockets ");
    debugWriteU64Decimal(network.udp_service_cycle.first_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.first_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.first_port);
    debugWrite(" and ");
    debugWriteU64Decimal(network.udp_service_cycle.second_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.second_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.second_port);
    debugWrite(", first dispatch ");
    debugWriteU64Decimal(network.udp_service_cycle.first_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.first_routed);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.first_dropped);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.first_remaining);
    debugWrite(" ready/pending ");
    debugWriteU64Decimal(network.udp_service_cycle.first_ready_count);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.first_total_pending);
    debugWrite(", second dispatch ");
    debugWriteU64Decimal(network.udp_service_cycle.second_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.second_routed);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.second_dropped);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.second_remaining);
    debugWrite(" ready/pending ");
    debugWriteU64Decimal(network.udp_service_cycle.second_ready_count);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.second_total_pending);
    debugWrite(", drained dispatch/ready ");
    debugWriteU64Decimal(network.udp_service_cycle.drained_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.drained_ready_count);
    debugWrite(", delivered ");
    debugWriteU64Decimal(network.udp_service_cycle.delivered_datagrams);
    debugWrite(", stale handles rejected ");
    debugWrite(if (network.udp_service_cycle.stale_first_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_service_cycle.stale_second_rejected) "yes" else "no");
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.udp_service_cycle.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_service_cycle.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_service_cycle.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.udp_dispatched);
    debugWrite(", drops unmatched/invalid ");
    debugWriteU64Decimal(network.udp_service_cycle.unmatched_dropped);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_service_cycle.invalid_udp_dropped);
    debugWrite("\r\n");

    debugWrite("e1000e UDP fair service verified: sockets ");
    debugWriteU64Decimal(network.udp_fair_service.first_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.first_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.first_port);
    debugWrite(" and ");
    debugWriteU64Decimal(network.udp_fair_service.second_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.second_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.second_port);
    debugWrite(", initial dispatch/ready/pending ");
    debugWriteU64Decimal(network.udp_fair_service.initial_dispatch_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.initial_dispatch_routed);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.initial_ready_count);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.initial_total_pending);
    debugWrite(", selections slot/gen/payload/cursor ");
    for (network.udp_fair_service.selection_slots, 0..) |slot, index| {
        if (index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(slot);
        debugWrite("/");
        debugWriteU64Decimal(network.udp_fair_service.selection_generations[index]);
        debugWrite("/");
        debugWriteU64Decimal(network.udp_fair_service.selection_payload_indexes[index]);
        debugWrite("/");
        debugWriteU64Decimal(network.udp_fair_service.ready_cursors_after[index]);
    }
    debugWrite(", empty/final cursor ");
    debugWriteU64Decimal(network.udp_fair_service.empty_ready_count);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.final_ready_cursor);
    debugWrite(", endpoints/ephemeral cursor ");
    debugWriteU64Decimal(network.udp_fair_service.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_fair_service.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_fair_service.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_fair_service.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("e1000e UDP automatic identification verified: socket ");
    debugWriteU64Decimal(network.udp_automatic_identification.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_automatic_identification.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_automatic_identification.local_port);
    debugWrite(", peer port ");
    debugWriteU64Decimal(network.udp_automatic_identification.peer_port);
    debugWrite(", unconnected/zero-TTL rejected ");
    debugWrite(if (network.udp_automatic_identification.unconnected_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_automatic_identification.zero_ttl_rejected) "yes" else "no");
    debugWrite(", cursor preserved ");
    debugWrite(if (network.udp_automatic_identification.cursor_preserved_on_failure) "yes" else "no");
    debugWrite(", IDs ");
    for (network.udp_automatic_identification.identifications, 0..) |identification, index| {
        if (index != 0) debugWrite("/");
        debugWrite("0x");
        debugWriteHex16(identification);
    }
    debugWrite(", descriptors ");
    for (network.udp_automatic_identification.descriptors, 0..) |value, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(value);
    }
    debugWrite(", cursors ");
    for (network.udp_automatic_identification.next_cursors, 0..) |value, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(value);
    }
    debugWrite(", frames ");
    for (network.udp_automatic_identification.frame_lengths, 0..) |value, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(value);
    }
    debugWrite(", final ID/TX cursor ");
    debugWriteU64Decimal(network.udp_automatic_identification.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_automatic_identification.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.udp_automatic_identification.tx_submissions_delta);
    debugWrite(", completions ");
    debugWriteU64Decimal(network.udp_automatic_identification.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_automatic_identification.tx_completion_dequeues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.udp_automatic_identification.completion_overflow);
    debugWrite(", pending TX/RX 0x");
    debugWriteHex64(network.udp_automatic_identification.tx_pending_mask);
    debugWrite("/0x");
    debugWriteHex64(network.udp_automatic_identification.rx_pending_mask);
    debugWrite(", endpoints/ephemeral cursor ");
    debugWriteU64Decimal(network.udp_automatic_identification.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_automatic_identification.final_ephemeral_cursor);
    debugWrite("\r\n");

    debugWrite("e1000e UDP payload boundary verified: socket ");
    debugWriteU64Decimal(network.udp_payload_boundary.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.local_port);
    debugWrite(", maximum/oversized ");
    debugWriteU64Decimal(network.udp_payload_boundary.maximum_payload_bytes);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.oversized_payload_bytes);
    debugWrite(", oversized rejected/cursor preserved ");
    debugWrite(if (network.udp_payload_boundary.oversized_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_payload_boundary.cursor_preserved_on_rejection) "yes" else "no");
    debugWrite(", maximum ID/descriptor/cursor/frame 0x");
    debugWriteHex16(network.udp_payload_boundary.maximum_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.maximum_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.maximum_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.maximum_frame_length);
    debugWrite(", empty ID/descriptor/cursor/frame 0x");
    debugWriteHex16(network.udp_payload_boundary.empty_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.empty_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.empty_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.empty_frame_length);
    debugWrite(", final ID/TX cursor ");
    debugWriteU64Decimal(network.udp_payload_boundary.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.udp_payload_boundary.tx_submissions_delta);
    debugWrite(", completions ");
    debugWriteU64Decimal(network.udp_payload_boundary.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.tx_completion_dequeues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.udp_payload_boundary.completion_overflow);
    debugWrite(", wraps unchanged ");
    debugWrite(if (network.udp_payload_boundary.tx_wraps_unchanged) "yes" else "no");
    debugWrite(", endpoints/ephemeral cursor ");
    debugWriteU64Decimal(network.udp_payload_boundary.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_payload_boundary.final_ephemeral_cursor);
    debugWrite("\r\n");

    debugWrite("e1000e UDP transmit wrap verified: socket ");
    debugWriteU64Decimal(network.udp_transmit_wrap.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_transmit_wrap.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_transmit_wrap.local_port);
    debugWrite(", IDs 0x");
    debugWriteHex16(network.udp_transmit_wrap.identifications[0]);
    debugWrite("/0x");
    debugWriteHex16(network.udp_transmit_wrap.identifications[1]);
    debugWrite(", descriptors ");
    debugWriteU64Decimal(network.udp_transmit_wrap.descriptors[0]);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_transmit_wrap.descriptors[1]);
    debugWrite(", cursors ");
    debugWriteU64Decimal(network.udp_transmit_wrap.next_cursors[0]);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_transmit_wrap.next_cursors[1]);
    debugWrite(", frames ");
    debugWriteU64Decimal(network.udp_transmit_wrap.frame_lengths[0]);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_transmit_wrap.frame_lengths[1]);
    debugWrite(", wraps ");
    debugWriteU64Decimal(network.udp_transmit_wrap.wraps_before);
    debugWrite("->");
    debugWriteU64Decimal(network.udp_transmit_wrap.wraps_after);
    debugWrite(" delta ");
    debugWriteU64Decimal(network.udp_transmit_wrap.wrap_delta);
    debugWrite(", final ID/TX cursor ");
    debugWriteU64Decimal(network.udp_transmit_wrap.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_transmit_wrap.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.udp_transmit_wrap.tx_submissions_delta);
    debugWrite(", completions ");
    debugWriteU64Decimal(network.udp_transmit_wrap.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_transmit_wrap.tx_completion_dequeues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.udp_transmit_wrap.completion_overflow);
    debugWrite(", pending TX/RX 0x");
    debugWriteHex64(network.udp_transmit_wrap.tx_pending_mask);
    debugWrite("/0x");
    debugWriteHex64(network.udp_transmit_wrap.rx_pending_mask);
    debugWrite(", endpoints/ephemeral cursor ");
    debugWriteU64Decimal(network.udp_transmit_wrap.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_transmit_wrap.final_ephemeral_cursor);
    debugWrite("\r\n");

    debugWrite("e1000e UDP receive-into verified: socket ");
    debugWriteU64Decimal(network.udp_receive_into.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.local_port);
    debugWrite(", first payload/copied/truncated/hash ");
    debugWriteU64Decimal(network.udp_receive_into.first_payload_length);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.first_copied_length);
    debugWrite("/");
    debugWrite(if (network.udp_receive_into.first_truncated) "yes" else "no");
    debugWrite("/0x");
    debugWriteHex64(network.udp_receive_into.first_copy_hash);
    debugWrite(", second ");
    debugWriteU64Decimal(network.udp_receive_into.second_payload_length);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.second_copied_length);
    debugWrite("/");
    debugWrite(if (network.udp_receive_into.second_truncated) "yes" else "no");
    debugWrite("/0x");
    debugWriteHex64(network.udp_receive_into.second_copy_hash);
    debugWrite(", empty ");
    debugWriteU64Decimal(network.udp_receive_into.empty_payload_length);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.empty_copied_length);
    debugWrite("/");
    debugWrite(if (network.udp_receive_into.empty_truncated) "yes" else "no");
    debugWrite(", source port ");
    debugWriteU64Decimal(network.udp_receive_into.source_port);
    debugWrite(", endpoint queue ");
    debugWriteU64Decimal(network.udp_receive_into.endpoint_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.endpoint_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.udp_receive_into.endpoint_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_receive_into.endpoint_dropped);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.udp_receive_into.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_receive_into.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_receive_into.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.udp_dispatched);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.udp_receive_into.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_receive_into.rx_completion_enqueues);
    debugWrite("\r\n");

    debugWrite("e1000e UDP peek/exact verified: socket ");
    debugWriteU64Decimal(network.udp_peek_exact.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peek_exact.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peek_exact.local_port);
    debugWrite(", first payload/ID ");
    debugWriteU64Decimal(network.udp_peek_exact.first_payload_length);
    debugWrite("/0x");
    debugWriteHex16(network.udp_peek_exact.first_identification);
    debugWrite(", repeated stable ");
    debugWrite(if (network.udp_peek_exact.repeated_preview_stable) "yes" else "no");
    debugWrite(", insufficient rejected/queue preserved ");
    debugWrite(if (network.udp_peek_exact.insufficient_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_peek_exact.queue_preserved_on_rejection) "yes" else "no");
    debugWrite(", first exact/hash ");
    debugWriteU64Decimal(network.udp_peek_exact.first_exact_copied);
    debugWrite("/0x");
    debugWriteHex64(network.udp_peek_exact.first_exact_hash);
    debugWrite(", second payload/ID/exact/hash ");
    debugWriteU64Decimal(network.udp_peek_exact.second_payload_length);
    debugWrite("/0x");
    debugWriteHex16(network.udp_peek_exact.second_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peek_exact.second_exact_copied);
    debugWrite("/0x");
    debugWriteHex64(network.udp_peek_exact.second_exact_hash);
    debugWrite(", final preview empty ");
    debugWrite(if (network.udp_peek_exact.final_preview_empty) "yes" else "no");
    debugWrite(", endpoint queue ");
    debugWriteU64Decimal(network.udp_peek_exact.endpoint_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peek_exact.endpoint_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.udp_peek_exact.endpoint_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_peek_exact.endpoint_dropped);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.udp_peek_exact.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peek_exact.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_peek_exact.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peek_exact.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_peek_exact.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peek_exact.udp_dispatched);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.udp_peek_exact.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_peek_exact.rx_completion_enqueues);
    debugWrite("\r\n");

    debugWrite("e1000e UDP discard-close verified: socket ");
    debugWriteU64Decimal(network.udp_discard_close.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_discard_close.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_discard_close.local_port);
    debugWrite(", peer ");
    debugWriteU64Decimal(network.udp_discard_close.peer_port);
    debugWrite(", normal close rejected ");
    debugWrite(if (network.udp_discard_close.normal_close_rejected) "yes" else "no");
    debugWrite(", discarded/connected ");
    debugWriteU64Decimal(network.udp_discard_close.discarded_packets);
    debugWrite("/");
    debugWrite(if (network.udp_discard_close.was_connected) "yes" else "no");
    debugWrite(", queue ");
    debugWriteU64Decimal(network.udp_discard_close.queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_discard_close.queue_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.udp_discard_close.queue_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.udp_discard_close.queue_dropped);
    debugWrite(", stale close/force/receive rejected ");
    debugWrite(if (network.udp_discard_close.stale_close_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_discard_close.stale_force_close_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_discard_close.stale_receive_rejected) "yes" else "no");
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.udp_discard_close.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_discard_close.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_discard_close.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_discard_close.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_discard_close.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_discard_close.udp_dispatched);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.udp_discard_close.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_discard_close.rx_completion_enqueues);
    debugWrite("\r\n");

    debugWrite("e1000e UDP send-to/reply verified: socket ");
    debugWriteU64Decimal(network.udp_send_to_reply.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.local_port);
    debugWrite(", request source/payload/hash ");
    debugWriteU64Decimal(network.udp_send_to_reply.request_source_port);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.request_payload_length);
    debugWrite("/0x");
    debugWriteHex64(network.udp_send_to_reply.request_payload_hash);
    debugWrite(", invalid peer/zero-TTL rejected ");
    debugWrite(if (network.udp_send_to_reply.invalid_peer_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.udp_send_to_reply.zero_ttl_rejected) "yes" else "no");
    debugWrite(", cursor preserved ");
    debugWrite(if (network.udp_send_to_reply.cursor_preserved_on_rejection) "yes" else "no");
    debugWrite(", reply ID/descriptor/cursor/frame 0x");
    debugWriteHex16(network.udp_send_to_reply.reply_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.reply_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.reply_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.reply_frame_length);
    debugWrite(", send-to 0x");
    debugWriteHex16(network.udp_send_to_reply.send_to_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.send_to_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.send_to_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.send_to_frame_length);
    debugWrite(", final ID/TX cursor ");
    debugWriteU64Decimal(network.udp_send_to_reply.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.udp_send_to_reply.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.udp_send_to_reply.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.udp_send_to_reply.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.udp_send_to_reply.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.udp_send_to_reply.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.udp_send_to_reply.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.udp_send_to_reply.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS codec verified: transaction 0x");
    debugWriteHex16(network.dns_codec.transaction_id);
    debugWrite(", query length/hash ");
    debugWriteU64Decimal(network.dns_codec.query_length);
    debugWrite("/0x");
    debugWriteHex64(network.dns_codec.query_hash);
    debugWrite(", response length/hash ");
    debugWriteU64Decimal(network.dns_codec.response_length);
    debugWrite("/0x");
    debugWriteHex64(network.dns_codec.response_hash);
    debugWrite(", A ");
    debugWriteIpv4(network.dns_codec.address);
    debugWrite(", TTL ");
    debugWriteU64Decimal(network.dns_codec.ttl);
    debugWrite(", authoritative/recursion ");
    debugWrite(if (network.dns_codec.authoritative) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_codec.recursion_available) "yes" else "no");
    debugWrite(", rejects names/small/ID/truncated/loop/error/type ");
    debugWrite(if (network.dns_codec.invalid_names_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_codec.small_buffer_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_codec.wrong_transaction_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_codec.truncated_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_codec.compression_loop_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_codec.error_response_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_codec.wrong_type_rejected) "yes" else "no");
    debugWrite(", case-insensitive ");
    debugWrite(if (network.dns_codec.case_insensitive_match) "yes" else "no");
    debugWrite("\r\n");

    debugWrite("DNS transaction verified: socket ");
    debugWriteU64Decimal(network.dns_transaction.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.dns_transaction.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.dns_transaction.server_port);
    debugWrite(", transaction 0x");
    debugWriteHex16(network.dns_transaction.transaction_id);
    debugWrite(", invalid name/cursor preserved ");
    debugWrite(if (network.dns_transaction.invalid_name_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_transaction.cursor_preserved_on_rejection) "yes" else "no");
    debugWrite(", query length/hash ");
    debugWriteU64Decimal(network.dns_transaction.query_payload_length);
    debugWrite("/0x");
    debugWriteHex64(network.dns_transaction.query_payload_hash);
    debugWrite(", TX ID/descriptor/cursor/frame 0x");
    debugWriteHex16(network.dns_transaction.transmit_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.transmit_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.transmit_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.transmit_frame_length);
    debugWrite(", wrong transaction rejected ");
    debugWrite(if (network.dns_transaction.wrong_transaction_rejected) "yes" else "no");
    debugWrite(", A ");
    debugWriteIpv4(network.dns_transaction.address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_transaction.ttl);
    debugWrite(" authoritative/recursion ");
    debugWrite(if (network.dns_transaction.authoritative) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_transaction.recursion_available) "yes" else "no");
    debugWrite(", endpoint queue ");
    debugWriteU64Decimal(network.dns_transaction.endpoint_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.endpoint_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.dns_transaction.endpoint_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.dns_transaction.endpoint_dropped);
    debugWrite(", final ID/TX cursor ");
    debugWriteU64Decimal(network.dns_transaction.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_transaction.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_transaction.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_transaction.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_transaction.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_transaction.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_transaction.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_transaction.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS polling verified: socket ");
    debugWriteU64Decimal(network.dns_polling.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.dns_polling.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.dns_polling.server_port);
    debugWrite(", transaction 0x");
    debugWriteHex16(network.dns_polling.transaction_id);
    debugWrite(", name length/hash ");
    debugWriteU64Decimal(network.dns_polling.name_length);
    debugWrite("/0x");
    debugWriteHex64(network.dns_polling.name_hash);
    debugWrite(", invalid/cursor preserved ");
    debugWrite(if (network.dns_polling.invalid_request_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_polling.cursor_preserved_on_rejection) "yes" else "no");
    debugWrite(", TX ID/descriptor/cursor/frame 0x");
    debugWriteHex16(network.dns_polling.transmit_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.transmit_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.transmit_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.transmit_frame_length);
    debugWrite(", zero state/examined/rejected/remaining ");
    debugWriteDnsState(network.dns_polling.zero_budget_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.zero_budget_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.zero_budget_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.zero_budget_remaining);
    debugWrite(", first ");
    debugWriteDnsState(network.dns_polling.first_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.first_poll_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.first_poll_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.first_poll_remaining);
    debugWrite(", second ");
    debugWriteDnsState(network.dns_polling.second_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.second_poll_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.second_poll_rejected);
    debugWrite(", A ");
    debugWriteIpv4(network.dns_polling.address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_polling.ttl);
    debugWrite(", stale ");
    debugWriteDnsState(network.dns_polling.stale_poll_state);
    debugWrite(", endpoint queue ");
    debugWriteU64Decimal(network.dns_polling.endpoint_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.endpoint_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.dns_polling.endpoint_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.dns_polling.endpoint_dropped);
    debugWrite(", final ID/TX cursor ");
    debugWriteU64Decimal(network.dns_polling.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_polling.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_polling.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_polling.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_polling.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_polling.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_polling.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_polling.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS alias verified: transaction 0x");
    debugWriteHex16(network.dns_alias.transaction_id);
    debugWrite(", alias length/hash ");
    debugWriteU64Decimal(network.dns_alias.alias_name_length);
    debugWrite("/0x");
    debugWriteHex64(network.dns_alias.alias_name_hash);
    debugWrite(", canonical length/hash ");
    debugWriteU64Decimal(network.dns_alias.canonical_name_length);
    debugWrite("/0x");
    debugWriteHex64(network.dns_alias.canonical_name_hash);
    debugWrite(", response length/hash ");
    debugWriteU64Decimal(network.dns_alias.response_length);
    debugWrite("/0x");
    debugWriteHex64(network.dns_alias.response_hash);
    debugWrite(", A ");
    debugWriteIpv4(network.dns_alias.address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_alias.ttl);
    debugWrite(" hops ");
    debugWriteU64Decimal(network.dns_alias.alias_hops);
    debugWrite(", loop/truncated rejected ");
    debugWrite(if (network.dns_alias.self_loop_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_alias.truncated_rejected) "yes" else "no");
    debugWrite(", case-insensitive ");
    debugWrite(if (network.dns_alias.case_insensitive_match) "yes" else "no");
    debugWrite("\r\n");

    debugWrite("DNS alias transaction verified: socket ");
    debugWriteU64Decimal(network.dns_alias_transaction.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.dns_alias_transaction.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.dns_alias_transaction.server_port);
    debugWrite(", transaction 0x");
    debugWriteHex16(network.dns_alias_transaction.transaction_id);
    debugWrite(", name length/hash ");
    debugWriteU64Decimal(network.dns_alias_transaction.name_length);
    debugWrite("/0x");
    debugWriteHex64(network.dns_alias_transaction.name_hash);
    debugWrite(", TX ID/descriptor/cursor/frame 0x");
    debugWriteHex16(network.dns_alias_transaction.transmit_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.transmit_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.transmit_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.transmit_frame_length);
    debugWrite(", poll ");
    debugWriteDnsState(network.dns_alias_transaction.poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.poll_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.poll_rejected);
    debugWrite(", A ");
    debugWriteIpv4(network.dns_alias_transaction.address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_alias_transaction.ttl);
    debugWrite(" hops ");
    debugWriteU64Decimal(network.dns_alias_transaction.alias_hops);
    debugWrite(", endpoint queue ");
    debugWriteU64Decimal(network.dns_alias_transaction.endpoint_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.endpoint_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.dns_alias_transaction.endpoint_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.dns_alias_transaction.endpoint_dropped);
    debugWrite(", final ID/TX cursor ");
    debugWriteU64Decimal(network.dns_alias_transaction.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_alias_transaction.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_alias_transaction.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_alias_transaction.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_alias_transaction.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_alias_transaction.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_alias_transaction.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_alias_transaction.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS retry verified: socket ");
    debugWriteU64Decimal(network.dns_retry.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.dns_retry.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.dns_retry.server_port);
    debugWrite(", transaction 0x");
    debugWriteHex16(network.dns_retry.transaction_id);
    debugWrite(", name length/hash ");
    debugWriteU64Decimal(network.dns_retry.name_length);
    debugWrite("/0x");
    debugWriteHex64(network.dns_retry.name_hash);
    debugWrite(", initial ID/descriptor/cursor/frame 0x");
    debugWriteHex16(network.dns_retry.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.initial_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.initial_frame_length);
    debugWrite(", pending ");
    debugWriteDnsState(network.dns_retry.pending_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.pending_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.pending_rejected);
    debugWrite(", retry 0x");
    debugWriteHex16(network.dns_retry.retry_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.retry_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.retry_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.retry_frame_length);
    debugWrite(", transmissions ");
    debugWriteU64Decimal(network.dns_retry.transmissions);
    debugWrite(", wraps ");
    debugWriteU64Decimal(network.dns_retry.tx_wraps_before);
    debugWrite("->");
    debugWriteU64Decimal(network.dns_retry.tx_wraps_after);
    debugWrite(", resolved ");
    debugWriteDnsState(network.dns_retry.resolved_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.resolved_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.resolved_rejected);
    debugWrite(", A ");
    debugWriteIpv4(network.dns_retry.address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_retry.ttl);
    debugWrite(", stale retry/cursor preserved ");
    debugWrite(if (network.dns_retry.stale_retry_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_retry.cursor_preserved_on_stale_retry) "yes" else "no");
    debugWrite(", final ID/TX cursor ");
    debugWriteU64Decimal(network.dns_retry.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_retry.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_retry.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_retry.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_retry.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_retry.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_retry.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_retry.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS cache verified: capacity/active ");
    debugWriteU64Decimal(network.dns_cache.capacity);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cache.active_entries);
    debugWrite(", invalid/zero-TTL rejected ");
    debugWrite(if (network.dns_cache.invalid_store_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_cache.zero_ttl_rejected) "yes" else "no");
    debugWrite(", case hit/TTL ");
    debugWrite(if (network.dns_cache.case_insensitive_hit) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cache.first_ttl_remaining);
    debugWrite(", eviction/expiration/refresh ");
    debugWrite(if (network.dns_cache.eviction_verified) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_cache.expiration_verified) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_cache.refresh_verified) "yes" else "no");
    debugWrite(", refreshed A ");
    debugWriteIpv4(network.dns_cache.refreshed_address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_cache.refreshed_ttl_remaining);
    debugWrite(", stats hits/misses/stores/refreshes/evictions/expirations ");
    debugWriteU64Decimal(network.dns_cache.hits);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cache.misses);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cache.stores);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cache.refreshes);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cache.evictions);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cache.expirations);
    debugWrite("\r\n");

    debugWrite("DNS cached resolve verified: socket ");
    debugWriteU64Decimal(network.dns_cached_resolve.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.dns_cached_resolve.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.dns_cached_resolve.server_port);
    debugWrite(", transaction 0x");
    debugWriteHex16(network.dns_cached_resolve.transaction_id);
    debugWrite(", miss TX 0x");
    debugWriteHex16(network.dns_cached_resolve.miss_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.miss_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.miss_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.miss_frame_length);
    debugWrite(", resolved ");
    debugWriteDnsState(network.dns_cached_resolve.resolved_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.resolved_examined);
    debugWrite(" A ");
    debugWriteIpv4(network.dns_cached_resolve.address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_cached_resolve.ttl);
    debugWrite(" stores ");
    debugWriteU64Decimal(network.dns_cached_resolve.cache_store_count);
    debugWrite(", cached hit/no-TX ");
    debugWrite(if (network.dns_cached_resolve.cached_hit) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_cached_resolve.cached_hit_no_tx) "yes" else "no");
    debugWrite(" A ");
    debugWriteIpv4(network.dns_cached_resolve.cached_address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_cached_resolve.cached_ttl_remaining);
    debugWrite(", expiry requery 0x");
    debugWriteHex16(network.dns_cached_resolve.expiry_requery_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.expiry_requery_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.expiry_requery_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.expiry_requery_frame_length);
    debugWrite(", stale pending ");
    debugWriteDnsState(network.dns_cached_resolve.stale_pending_state);
    debugWrite(", final ID/TX cursor ");
    debugWriteU64Decimal(network.dns_cached_resolve.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_cached_resolve.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_cached_resolve.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_cached_resolve.completion_overflow);
    debugWrite(", cache hits/misses/expirations/active ");
    debugWriteU64Decimal(network.dns_cached_resolve.cache_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.cache_misses);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.cache_expirations);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.cache_active_entries);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_cached_resolve.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_cached_resolve.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_cached_resolve.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cached_resolve.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS automatic transactions verified: socket ");
    debugWriteU64Decimal(network.dns_automatic_transaction.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_transaction.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_transaction.local_port);
    debugWrite(", invalid/cursors preserved ");
    debugWrite(if (network.dns_automatic_transaction.invalid_name_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_automatic_transaction.invalid_name_cursors_preserved) "yes" else "no");
    debugWrite(", DNS IDs ");
    for (network.dns_automatic_transaction.transaction_ids, 0..) |value, index| {
        if (index != 0) debugWrite("/");
        debugWrite("0x");
        debugWriteHex16(value);
    }
    debugWrite(", packet IDs ");
    for (network.dns_automatic_transaction.packet_identifications, 0..) |value, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(value);
    }
    debugWrite(", descriptors ");
    for (network.dns_automatic_transaction.descriptors, 0..) |value, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(value);
    }
    debugWrite(", cursors ");
    for (network.dns_automatic_transaction.next_cursors, 0..) |value, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(value);
    }
    debugWrite(", frames ");
    for (network.dns_automatic_transaction.frame_lengths, 0..) |value, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(value);
    }
    debugWrite(", transmissions ");
    for (network.dns_automatic_transaction.transmission_counts, 0..) |value, index| {
        if (index != 0) debugWrite("/");
        debugWriteU64Decimal(value);
    }
    debugWrite(", stale/cursors preserved ");
    debugWrite(if (network.dns_automatic_transaction.stale_socket_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_automatic_transaction.stale_socket_cursors_preserved) "yes" else "no");
    debugWrite(", final DNS/IP/TX cursors ");
    debugWriteU64Decimal(network.dns_automatic_transaction.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_transaction.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_transaction.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_automatic_transaction.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_automatic_transaction.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_transaction.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_transaction.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_automatic_transaction.completion_overflow);
    debugWrite(", wraps unchanged ");
    debugWrite(if (network.dns_automatic_transaction.tx_wraps_unchanged) "yes" else "no");
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_automatic_transaction.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_transaction.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_automatic_transaction.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_transaction.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_automatic_transaction.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_transaction.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS automatic cached resolve verified: socket ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.dns_automatic_cached_resolve.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.server_port);
    debugWrite(", preload ");
    debugWrite(if (network.dns_automatic_cached_resolve.preload_stored) "yes" else "no");
    debugWrite(", initial hit/TTL/no-TX ");
    debugWrite(if (network.dns_automatic_cached_resolve.initial_cached_hit) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.initial_cached_ttl);
    debugWrite("/");
    debugWrite(if (network.dns_automatic_cached_resolve.initial_hit_no_tx) "yes" else "no");
    debugWrite(", expired DNS/IP/descriptor/cursor/frame 0x");
    debugWriteHex16(network.dns_automatic_cached_resolve.expired_transaction_id);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.expired_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.expired_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.expired_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.expired_frame_length);
    debugWrite(", resolved ");
    debugWriteDnsState(network.dns_automatic_cached_resolve.resolved_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.resolved_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.resolved_rejected);
    debugWrite(" A ");
    debugWriteIpv4(network.dns_automatic_cached_resolve.resolved_address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.resolved_ttl);
    debugWrite(", refreshed hit/TTL/no-TX ");
    debugWrite(if (network.dns_automatic_cached_resolve.refreshed_cached_hit) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.refreshed_cached_ttl);
    debugWrite("/");
    debugWrite(if (network.dns_automatic_cached_resolve.refreshed_hit_no_tx) "yes" else "no");
    debugWrite(", invalid/cursors preserved ");
    debugWrite(if (network.dns_automatic_cached_resolve.invalid_name_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_automatic_cached_resolve.invalid_name_cursors_preserved) "yes" else "no");
    debugWrite(", final DNS/IP/TX cursors ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.completion_overflow);
    debugWrite(", cache hits/misses/stores/expirations/active ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.cache_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.cache_misses);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.cache_stores);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.cache_expirations);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.cache_active_entries);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_automatic_cached_resolve.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS negative response verified: socket ");
    debugWriteU64Decimal(network.dns_negative.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.dns_negative.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.dns_negative.server_port);
    debugWrite(", transaction 0x");
    debugWriteHex16(network.dns_negative.transaction_id);
    debugWrite(", TX ID/descriptor/cursor/frame ");
    debugWriteU64Decimal(network.dns_negative.transmit_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.transmit_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.transmit_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.transmit_frame_length);
    debugWrite(", poll ");
    debugWriteDnsState(network.dns_negative.poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.poll_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.poll_rejected);
    debugWrite(", response absent/queue empty ");
    debugWrite(if (network.dns_negative.response_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_negative.queue_empty) "yes" else "no");
    debugWrite(", stale ");
    debugWriteDnsState(network.dns_negative.stale_state);
    debugWrite(", final DNS/IP/TX cursors ");
    debugWriteU64Decimal(network.dns_negative.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_negative.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_negative.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_negative.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_negative.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_negative.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_negative.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS negative cache verified: socket ");
    debugWriteU64Decimal(network.dns_negative_cache.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.dns_negative_cache.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.dns_negative_cache.server_port);
    debugWrite(", initial DNS/IP/descriptor/cursor/frame ");
    debugWriteU64Decimal(network.dns_negative_cache.transaction_id);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.transmit_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.transmit_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.transmit_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.transmit_frame_length);
    debugWrite(", poll/stored ");
    debugWriteDnsState(network.dns_negative_cache.poll_state);
    debugWrite("/");
    debugWrite(if (network.dns_negative_cache.negative_stored) "yes" else "no");
    debugWrite(", cached not-found/TTL/no-TX ");
    debugWrite(if (network.dns_negative_cache.cached_not_found) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.cached_ttl_remaining);
    debugWrite("/");
    debugWrite(if (network.dns_negative_cache.cached_hit_no_tx) "yes" else "no");
    debugWrite(", expiry DNS/IP/descriptor/cursor/frame ");
    debugWriteU64Decimal(network.dns_negative_cache.expiry_transaction_id);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.expiry_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.expiry_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.expiry_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.expiry_frame_length);
    debugWrite(", stale ");
    debugWriteDnsState(network.dns_negative_cache.stale_state);
    debugWrite(", final DNS/IP/TX cursors ");
    debugWriteU64Decimal(network.dns_negative_cache.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_negative_cache.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_negative_cache.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_negative_cache.completion_overflow);
    debugWrite(", cache hits/misses/stores/expirations/active ");
    debugWriteU64Decimal(network.dns_negative_cache.cache_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.cache_misses);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.cache_stores);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.cache_expirations);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.cache_active_entries);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_negative_cache.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_negative_cache.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_negative_cache.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_negative_cache.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS cancellation verified: socket ");
    debugWriteU64Decimal(network.dns_cancellation.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.local_port);
    debugWrite(", DNS/IP/descriptor/cursor/frame ");
    debugWriteU64Decimal(network.dns_cancellation.transaction_id);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.transmit_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.transmit_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.transmit_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.transmit_frame_length);
    debugWrite(", queued ");
    debugWriteU64Decimal(network.dns_cancellation.queued_before_cancel);
    debugWrite(", cancel/duplicate rejected ");
    debugWrite(if (network.dns_cancellation.cancelled) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_cancellation.duplicate_cancel_rejected) "yes" else "no");
    debugWrite(", poll ");
    debugWriteDnsState(network.dns_cancellation.poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.poll_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.poll_rejected);
    debugWrite(", queue preserved ");
    debugWrite(if (network.dns_cancellation.queue_preserved) "yes" else "no");
    debugWrite(", retry/cursors preserved ");
    debugWrite(if (network.dns_cancellation.retry_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_cancellation.retry_cursors_preserved) "yes" else "no");
    debugWrite(", normal close rejected/discarded ");
    debugWrite(if (network.dns_cancellation.normal_close_rejected) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.discarded_packets);
    debugWrite(", stale poll ");
    debugWriteDnsState(network.dns_cancellation.stale_poll_state);
    debugWrite(", final DNS/IP/TX cursors ");
    debugWriteU64Decimal(network.dns_cancellation.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_cancellation.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_cancellation.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_cancellation.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_cancellation.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_cancellation.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_cancellation.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_cancellation.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("DNS resolver context verified: socket ");
    debugWriteU64Decimal(network.dns_resolver_context.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.dns_resolver_context.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.dns_resolver_context.server_port);
    debugWrite(", invalid/state preserved ");
    debugWrite(if (network.dns_resolver_context.invalid_server_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_resolver_context.invalid_server_state_preserved) "yes" else "no");
    debugWrite(", DNS/IP/descriptor/cursor/frame ");
    debugWriteU64Decimal(network.dns_resolver_context.transaction_id);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.transmit_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.transmit_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.transmit_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.transmit_frame_length);
    debugWrite(", resolved ");
    debugWriteDnsState(network.dns_resolver_context.resolved_state);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.resolved_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.resolved_rejected);
    debugWrite(" A ");
    debugWriteIpv4(network.dns_resolver_context.address);
    debugWrite(" TTL ");
    debugWriteU64Decimal(network.dns_resolver_context.ttl);
    debugWrite(", cached hit/TTL/no-TX ");
    debugWrite(if (network.dns_resolver_context.cached_hit) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.cached_ttl_remaining);
    debugWrite("/");
    debugWrite(if (network.dns_resolver_context.cached_hit_no_tx) "yes" else "no");
    debugWrite(", close/inactive/stale/state preserved ");
    debugWrite(if (network.dns_resolver_context.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_resolver_context.resolver_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_resolver_context.stale_start_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.dns_resolver_context.stale_state_preserved) "yes" else "no");
    debugWrite(", final DNS/IP/TX cursors ");
    debugWriteU64Decimal(network.dns_resolver_context.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.dns_resolver_context.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.dns_resolver_context.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.dns_resolver_context.completion_overflow);
    debugWrite(", cache hits/misses/stores/active ");
    debugWriteU64Decimal(network.dns_resolver_context.cache_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.cache_misses);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.cache_stores);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.cache_active_entries);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.dns_resolver_context.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.dns_resolver_context.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.dns_resolver_context.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.dns_resolver_context.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("NTP codec verified: client/server timestamp 0x");
    debugWriteHex64(network.ntp_codec.client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_codec.server_timestamp);
    debugWrite(", request length/hash ");
    debugWriteU64Decimal(network.ntp_codec.request_length);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_codec.request_hash);
    debugWrite(", response length/hash ");
    debugWriteU64Decimal(network.ntp_codec.response_length);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_codec.response_hash);
    debugWrite(", LI/version/stratum/poll/precision ");
    debugWriteU64Decimal(network.ntp_codec.leap_indicator);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_codec.version);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_codec.stratum);
    debugWrite("/");
    debugWriteI64Decimal(network.ntp_codec.poll);
    debugWrite("/");
    debugWriteI64Decimal(network.ntp_codec.precision);
    debugWrite(", root delay/dispersion 0x");
    debugWriteHex32(network.ntp_codec.root_delay);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_codec.root_dispersion);
    debugWrite(", reference ");
    debugWrite(network.ntp_codec.reference_id[0..]);
    debugWrite(", Unix seconds/fraction ");
    debugWriteU64Decimal(network.ntp_codec.unix_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_codec.unix_fraction);
    debugWrite(", rejects zero/small/mode/alarm/stratum/originate/transmit/epoch/truncated ");
    debugWrite(if (network.ntp_codec.zero_timestamp_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_codec.small_buffer_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_codec.wrong_mode_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_codec.alarm_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_codec.invalid_stratum_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_codec.wrong_originate_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_codec.zero_transmit_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_codec.pre_epoch_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_codec.truncated_rejected) "yes" else "no");
    debugWrite("\r\n");

    debugWrite("NTP transaction verified: socket ");
    debugWriteU64Decimal(network.ntp_transaction.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.ntp_transaction.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.ntp_transaction.server_port);
    debugWrite(", client timestamp 0x");
    debugWriteHex64(network.ntp_transaction.client_timestamp);
    debugWrite(", invalid/state preserved ");
    debugWrite(if (network.ntp_transaction.invalid_timestamp_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction.rejection_state_preserved) "yes" else "no");
    debugWrite(", TX ID/descriptor/cursor/frame ");
    debugWriteU64Decimal(network.ntp_transaction.transmit_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.transmit_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.transmit_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.transmit_frame_length);
    debugWrite(", wrong originate rejected ");
    debugWrite(if (network.ntp_transaction.wrong_originate_rejected) "yes" else "no");
    debugWrite(", Unix seconds/fraction ");
    debugWriteU64Decimal(network.ntp_transaction.unix_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_transaction.unix_fraction);
    debugWrite(", stratum/poll/precision ");
    debugWriteU64Decimal(network.ntp_transaction.stratum);
    debugWrite("/");
    debugWriteI64Decimal(network.ntp_transaction.poll);
    debugWrite("/");
    debugWriteI64Decimal(network.ntp_transaction.precision);
    debugWrite(", reference ");
    debugWrite(network.ntp_transaction.reference_id[0..]);
    debugWrite(", endpoint queue ");
    debugWriteU64Decimal(network.ntp_transaction.endpoint_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.endpoint_dequeued);
    debugWrite(" high-water ");
    debugWriteU64Decimal(network.ntp_transaction.endpoint_high_water);
    debugWrite(" dropped ");
    debugWriteU64Decimal(network.ntp_transaction.endpoint_dropped);
    debugWrite(", final IP/DNS/TX cursors ");
    debugWriteU64Decimal(network.ntp_transaction.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_transaction.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_transaction.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.ntp_transaction.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_transaction.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_transaction.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.ntp_transaction.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("NTP polling verified: poll socket ");
    debugWriteU64Decimal(network.ntp_polling.polling_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.polling_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.polling_port);
    debugWrite(", TX ");
    debugWriteU64Decimal(network.ntp_polling.polling_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.polling_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.polling_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.polling_frame_length);
    debugWrite(", zero ");
    debugWriteNtpState(network.ntp_polling.zero_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.zero_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.zero_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.zero_remaining);
    debugWrite(", first ");
    debugWriteNtpState(network.ntp_polling.first_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.first_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.first_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.first_remaining);
    debugWrite(", second ");
    debugWriteNtpState(network.ntp_polling.second_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.second_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.second_rejected);
    debugWrite(" time ");
    debugWriteU64Decimal(network.ntp_polling.unix_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_polling.unix_fraction);
    debugWrite(", cancel socket ");
    debugWriteU64Decimal(network.ntp_polling.cancellation_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.cancellation_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.cancellation_port);
    debugWrite(" TX ");
    debugWriteU64Decimal(network.ntp_polling.cancellation_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.cancellation_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.cancellation_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.cancellation_frame_length);
    debugWrite(", queued ");
    debugWriteU64Decimal(network.ntp_polling.queued_before_cancel);
    debugWrite(", cancel/duplicate ");
    debugWrite(if (network.ntp_polling.cancelled) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_polling.duplicate_cancel_rejected) "yes" else "no");
    debugWrite(", poll ");
    debugWriteNtpState(network.ntp_polling.cancelled_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.cancelled_poll_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.cancelled_poll_rejected);
    debugWrite(", queue preserved ");
    debugWrite(if (network.ntp_polling.queue_preserved) "yes" else "no");
    debugWrite(", close/discard ");
    debugWrite(if (network.ntp_polling.normal_close_rejected) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.discarded_packets);
    debugWrite(", final IP/DNS/TX ");
    debugWriteU64Decimal(network.ntp_polling.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_polling.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_polling.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.ntp_polling.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_polling.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_polling.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.ntp_polling.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_polling.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("NTP retry verified: socket ");
    debugWriteU64Decimal(network.ntp_retry.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.local_port);
    debugWrite(", client 0x");
    debugWriteHex64(network.ntp_retry.client_timestamp);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_retry.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.initial_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.initial_frame_length);
    debugWrite(", pending ");
    debugWriteNtpState(network.ntp_retry.pending_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.pending_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.pending_rejected);
    debugWrite(", retry ");
    debugWriteU64Decimal(network.ntp_retry.retry_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.retry_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.retry_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.retry_frame_length);
    debugWrite(", transmissions ");
    debugWriteU64Decimal(network.ntp_retry.transmissions);
    debugWrite(", wraps ");
    debugWriteU64Decimal(network.ntp_retry.wraps_before);
    debugWrite("->");
    debugWriteU64Decimal(network.ntp_retry.wraps_after);
    debugWrite(", resolved ");
    debugWriteNtpState(network.ntp_retry.resolved_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.resolved_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.resolved_rejected);
    debugWrite(" time ");
    debugWriteU64Decimal(network.ntp_retry.unix_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_retry.unix_fraction);
    debugWrite(", stale/state preserved ");
    debugWrite(if (network.ntp_retry.stale_retry_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_retry.stale_retry_state_preserved) "yes" else "no");
    debugWrite(", final IP/DNS/TX ");
    debugWriteU64Decimal(network.ntp_retry.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_retry.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_retry.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.ntp_retry.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_retry.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_retry.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.ntp_retry.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("NTP client context verified: socket ");
    debugWriteU64Decimal(network.ntp_client_context.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.ntp_client_context.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.ntp_client_context.server_port);
    debugWrite(", invalid/state preserved ");
    debugWrite(if (network.ntp_client_context.invalid_server_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_context.invalid_server_state_preserved) "yes" else "no");
    debugWrite(", client 0x");
    debugWriteHex64(network.ntp_client_context.client_timestamp);
    debugWrite(", TX ");
    debugWriteU64Decimal(network.ntp_client_context.transmit_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.transmit_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.transmit_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.transmit_frame_length);
    debugWrite(", poll ");
    debugWriteNtpState(network.ntp_client_context.poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.poll_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.poll_rejected);
    debugWrite(" time ");
    debugWriteU64Decimal(network.ntp_client_context.unix_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_client_context.unix_fraction);
    debugWrite(", close/inactive/stale start/poll/retry/state ");
    debugWrite(if (network.ntp_client_context.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_context.client_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_context.stale_start_rejected) "yes" else "no");
    debugWrite("/");
    debugWriteNtpState(network.ntp_client_context.stale_poll_state);
    debugWrite("/");
    debugWrite(if (network.ntp_client_context.stale_retry_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_context.stale_state_preserved) "yes" else "no");
    debugWrite(", final IP/DNS/TX ");
    debugWriteU64Decimal(network.ntp_client_context.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_client_context.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_client_context.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.ntp_client_context.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_client_context.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_client_context.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.ntp_client_context.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_context.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("NTP clock verified: initially unsynchronized ");
    debugWrite(if (network.ntp_clock.initially_unsynchronized) "yes" else "no");
    debugWrite(", apply first/duplicate/backward/fraction/second ");
    debugWriteNtpApply(network.ntp_clock.first_apply);
    debugWrite("/");
    debugWriteNtpApply(network.ntp_clock.duplicate_apply);
    debugWrite("/");
    debugWriteNtpApply(network.ntp_clock.backward_apply);
    debugWrite("/");
    debugWriteNtpApply(network.ntp_clock.fractional_forward_apply);
    debugWrite("/");
    debugWriteNtpApply(network.ntp_clock.second_forward_apply);
    debugWrite(", duplicate/backward preserved ");
    debugWrite(if (network.ntp_clock.duplicate_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_clock.backward_preserved) "yes" else "no");
    debugWrite(", final seconds/fraction ");
    debugWriteU64Decimal(network.ntp_clock.final_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_clock.final_fraction);
    debugWrite(", stratum/reference ");
    debugWriteU64Decimal(network.ntp_clock.final_stratum);
    debugWrite("/");
    debugWrite(network.ntp_clock.final_reference_id[0..]);
    debugWrite(", accepted/stale ");
    debugWriteU64Decimal(network.ntp_clock.accepted_samples);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock.stale_samples);
    debugWrite("\r\n");

    debugWrite("NTP clock polling verified: socket ");
    debugWriteU64Decimal(network.ntp_clock_polling.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.ntp_clock_polling.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.ntp_clock_polling.server_port);
    debugWrite(", first TX ");
    debugWriteU64Decimal(network.ntp_clock_polling.first_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.first_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.first_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.first_frame_length);
    debugWrite(", zero ");
    debugWriteNtpState(network.ntp_clock_polling.zero_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.zero_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.zero_rejected);
    debugWrite("/apply absent ");
    debugWrite(if (network.ntp_clock_polling.zero_apply_absent) "yes" else "no");
    debugWrite("/queue ");
    debugWriteU64Decimal(network.ntp_clock_polling.zero_queue_remaining);
    debugWrite("/clock unsynchronized ");
    debugWrite(if (network.ntp_clock_polling.zero_clock_unsynchronized) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpState(network.ntp_clock_polling.accepted_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.accepted_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.accepted_rejected);
    debugWrite("/apply ");
    debugWriteNtpApply(network.ntp_clock_polling.accepted_apply);
    debugWrite(" time ");
    debugWriteU64Decimal(network.ntp_clock_polling.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_clock_polling.accepted_fraction);
    debugWrite(", second TX ");
    debugWriteU64Decimal(network.ntp_clock_polling.second_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.second_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.second_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.second_frame_length);
    debugWrite(", duplicate ");
    debugWriteNtpState(network.ntp_clock_polling.duplicate_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.duplicate_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.duplicate_rejected);
    debugWrite("/apply ");
    debugWriteNtpApply(network.ntp_clock_polling.duplicate_apply);
    debugWrite("/clock preserved ");
    debugWrite(if (network.ntp_clock_polling.duplicate_clock_preserved) "yes" else "no");
    debugWrite(", samples ");
    debugWriteU64Decimal(network.ntp_clock_polling.accepted_samples);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.stale_samples);
    debugWrite(", close/inactive/apply absent/clock preserved ");
    debugWrite(if (network.ntp_clock_polling.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWriteNtpState(network.ntp_clock_polling.inactive_state);
    debugWrite("/");
    debugWrite(if (network.ntp_clock_polling.inactive_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_clock_polling.inactive_clock_preserved) "yes" else "no");
    debugWrite(", final IP/DNS/TX ");
    debugWriteU64Decimal(network.ntp_clock_polling.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_clock_polling.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_clock_polling.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.ntp_clock_polling.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_clock_polling.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_clock_polling.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.ntp_clock_polling.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_clock_polling.udp_dispatched);
    debugWrite("\r\n");

    debugWrite("NTP projected clock verified: invalid frequency/state preserved ");
    debugWrite(if (network.ntp_projected_clock.invalid_frequency_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_projected_clock.invalid_frequency_state_preserved) "yes" else "no");
    debugWrite(", initially unsynchronized ");
    debugWrite(if (network.ntp_projected_clock.initially_unsynchronized) "yes" else "no");
    debugWrite(", first apply ");
    debugWriteNtpApply(network.ntp_projected_clock.first_apply);
    debugWrite(" at tick/frequency ");
    debugWriteU64Decimal(network.ntp_projected_clock.first_anchor_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_projected_clock.first_frequency);
    debugWrite(", quarter ");
    debugWriteU64Decimal(network.ntp_projected_clock.quarter_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_projected_clock.quarter_fraction);
    debugWrite(", three-quarter ");
    debugWriteU64Decimal(network.ntp_projected_clock.three_quarter_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_projected_clock.three_quarter_fraction);
    debugWrite(", one-second ");
    debugWriteU64Decimal(network.ntp_projected_clock.one_second_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_projected_clock.one_second_fraction);
    debugWrite(", backward tick rejected ");
    debugWrite(if (network.ntp_projected_clock.backward_tick_rejected) "yes" else "no");
    debugWrite(", resync ");
    debugWriteNtpApply(network.ntp_projected_clock.resync_apply);
    debugWrite(" at ");
    debugWriteU64Decimal(network.ntp_projected_clock.resync_anchor_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_projected_clock.resync_frequency);
    debugWrite(" time ");
    debugWriteU64Decimal(network.ntp_projected_clock.resync_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_projected_clock.resync_fraction);
    debugWrite(" stratum/reference ");
    debugWriteU64Decimal(network.ntp_projected_clock.resync_stratum);
    debugWrite("/");
    debugWrite(network.ntp_projected_clock.resync_reference_id[0..]);
    debugWrite(", quarter after resync ");
    debugWriteU64Decimal(network.ntp_projected_clock.resync_quarter_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_projected_clock.resync_quarter_fraction);
    debugWrite(", stale apply/preserved ");
    debugWriteNtpApply(network.ntp_projected_clock.stale_apply);
    debugWrite("/");
    debugWrite(if (network.ntp_projected_clock.stale_state_preserved) "yes" else "no");
    debugWrite(", samples ");
    debugWriteU64Decimal(network.ntp_projected_clock.accepted_samples);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_projected_clock.stale_samples);
    debugWrite("\r\n");

    debugWrite("NTP reference clock verified: source ");
    debugWriteReferenceKind(network.ntp_reference_clock.source_kind);
    debugWrite(", frequency ");
    debugWriteU64Decimal(network.ntp_reference_clock.frequency_hz);
    debugWrite(" Hz, bits ");
    debugWriteU64Decimal(network.ntp_reference_clock.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_reference_clock.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.local_port);
    debugWrite(", server ");
    debugWriteIpv4(network.ntp_reference_clock.server_ipv4);
    debugWrite(":");
    debugWriteU64Decimal(network.ntp_reference_clock.server_port);
    debugWrite(", first TX ");
    debugWriteU64Decimal(network.ntp_reference_clock.first_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.first_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.first_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.first_frame_length);
    debugWrite(", zero ");
    debugWriteNtpState(network.ntp_reference_clock.zero_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.zero_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.zero_rejected);
    debugWrite("/sample absent ");
    debugWrite(if (network.ntp_reference_clock.zero_sample_absent) "yes" else "no");
    debugWrite("/apply absent ");
    debugWrite(if (network.ntp_reference_clock.zero_apply_absent) "yes" else "no");
    debugWrite("/queue ");
    debugWriteU64Decimal(network.ntp_reference_clock.zero_queue_remaining);
    debugWrite(", accepted ");
    debugWriteNtpState(network.ntp_reference_clock.accepted_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.accepted_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.accepted_rejected);
    debugWrite("/sample ");
    debugWriteU64Decimal(network.ntp_reference_clock.accepted_sample_tick);
    debugWrite("/apply ");
    debugWriteNtpApply(network.ntp_reference_clock.accepted_apply);
    debugWrite(" time ");
    debugWriteU64Decimal(network.ntp_reference_clock.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_reference_clock.accepted_fraction);
    debugWrite(", later tick/delta ");
    debugWriteU64Decimal(network.ntp_reference_clock.later_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.later_delta);
    debugWrite(" time ");
    debugWriteU64Decimal(network.ntp_reference_clock.later_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_reference_clock.later_fraction);
    debugWrite(" advanced ");
    debugWrite(if (network.ntp_reference_clock.time_advanced) "yes" else "no");
    debugWrite(", second TX ");
    debugWriteU64Decimal(network.ntp_reference_clock.second_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.second_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.second_next_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.second_frame_length);
    debugWrite(", duplicate ");
    debugWriteNtpState(network.ntp_reference_clock.duplicate_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.duplicate_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.duplicate_rejected);
    debugWrite("/sample ");
    debugWriteU64Decimal(network.ntp_reference_clock.duplicate_sample_tick);
    debugWrite("/apply ");
    debugWriteNtpApply(network.ntp_reference_clock.duplicate_apply);
    debugWrite("/clock preserved ");
    debugWrite(if (network.ntp_reference_clock.duplicate_clock_preserved) "yes" else "no");
    debugWrite(", close/inactive/sample/apply absent/clock preserved ");
    debugWrite(if (network.ntp_reference_clock.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWriteNtpState(network.ntp_reference_clock.inactive_state);
    debugWrite("/");
    debugWrite(if (network.ntp_reference_clock.inactive_sample_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_reference_clock.inactive_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_reference_clock.inactive_clock_preserved) "yes" else "no");
    debugWrite(", final IP/DNS/TX ");
    debugWriteU64Decimal(network.ntp_reference_clock.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.final_dns_transaction_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_reference_clock.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_reference_clock.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.rx_completion_enqueues);
    debugWrite(", overflow ");
    debugWriteU64Decimal(network.ntp_reference_clock.completion_overflow);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_reference_clock.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_reference_clock.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.ingress_dequeued);
    debugWrite(", dispatch total/UDP ");
    debugWriteU64Decimal(network.ntp_reference_clock.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_reference_clock.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP service verified: source ");
    debugWriteReferenceKind(network.ntp_service.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_service.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_service.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.local_port);
    debugWrite(", invalid policy/state preserved ");
    debugWrite(if (network.ntp_service.invalid_policy_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service.invalid_policy_state_preserved) "yes" else "no");
    debugWrite(", policy ");
    debugWriteU64Decimal(network.ntp_service.quality_policy_max_stratum);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_service.quality_policy_max_root_delay);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_service.quality_policy_max_root_dispersion);
    debugWrite(", bootstrap rejected/state preserved ");
    debugWrite(if (network.ntp_service.bootstrap_zero_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service.bootstrap_state_preserved) "yes" else "no");
    debugWrite(", initial timestamp 0x");
    debugWriteHex64(network.ntp_service.initial_client_timestamp);
    debugWrite(", intervals ");
    debugWriteU64Decimal(network.ntp_service.retry_interval_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.refresh_interval_ticks);
    debugWrite(", initial TX ");
    debugWriteU64Decimal(network.ntp_service.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.initial_next_cursor);
    debugWrite(", early no-TX ");
    debugWrite(if (network.ntp_service.early_no_tx) "yes" else "no");
    debugWrite(", retry TX ");
    debugWriteU64Decimal(network.ntp_service.retry_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.retry_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.retry_next_cursor);
    debugWrite(" transmissions ");
    debugWriteU64Decimal(network.ntp_service.retry_transmissions);
    debugWrite(" timestamp preserved ");
    debugWrite(if (network.ntp_service.retry_timestamp_preserved) "yes" else "no");
    debugWrite(", quality reject ");
    debugWriteNtpQuality(network.ntp_service.quality_rejection_reason);
    debugWrite("/sample absent/request retained ");
    debugWrite(if (network.ntp_service.quality_rejected_without_sample) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service.quality_request_retained) "yes" else "no");
    debugWrite(", first sample ");
    debugWriteU64Decimal(network.ntp_service.first_sample_tick);
    debugWrite(" time ");
    debugWriteU64Decimal(network.ntp_service.first_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_service.first_fraction);
    debugWrite(" deadline ");
    debugWriteU64Decimal(network.ntp_service.first_refresh_deadline);
    debugWrite(", pre-anchor idle preserved ");
    debugWrite(if (network.ntp_service.pre_anchor_idle_preserved) "yes" else "no");
    debugWrite(", before refresh no-TX ");
    debugWrite(if (network.ntp_service.before_refresh_no_tx) "yes" else "no");
    debugWrite(", refresh timestamp 0x");
    debugWriteHex64(network.ntp_service.refresh_client_timestamp);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_service.refresh_timestamp_automatic) "yes" else "no");
    debugWrite(", refresh TX ");
    debugWriteU64Decimal(network.ntp_service.refresh_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.refresh_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.refresh_next_cursor);
    debugWrite(", second sample ");
    debugWriteU64Decimal(network.ntp_service.second_sample_tick);
    debugWrite(" time ");
    debugWriteU64Decimal(network.ntp_service.second_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_service.second_fraction);
    debugWrite(", counts ");
    debugWriteU64Decimal(network.ntp_service.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.responses);
    debugWrite(", quality counts ");
    debugWriteU64Decimal(network.ntp_service.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.quality_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.quality_invalid_policy_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.quality_stratum_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.quality_root_delay_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.quality_root_dispersion_rejected);
    debugWrite(", close/inactive preserved ");
    debugWrite(if (network.ntp_service.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service.inactive_preserved) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_service.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_service.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_service.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_service.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_service.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_service.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP backoff verified: source ");
    debugWriteReferenceKind(network.ntp_backoff.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_backoff.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.counter_bits);
    debugWrite(", invalid policy/state preserved ");
    debugWrite(if (network.ntp_backoff.invalid_policy_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_backoff.invalid_policy_state_preserved) "yes" else "no");
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_backoff.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.local_port);
    debugWrite(", policy ");
    debugWriteU64Decimal(network.ntp_backoff.initial_interval_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.maximum_interval_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.maximum_retries);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_backoff.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.initial_next_cursor);
    debugWrite(" wait ");
    debugWriteU64Decimal(network.ntp_backoff.initial_wait_ticks);
    debugWrite(", early no-TX ");
    debugWrite(if (network.ntp_backoff.early_no_tx) "yes" else "no");
    debugWrite(", retries ");
    var backoff_index: usize = 0;
    while (backoff_index < network.ntp_backoff.retry_identifications.len) : (backoff_index += 1) {
        if (backoff_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_backoff.retry_identifications[backoff_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_backoff.retry_descriptors[backoff_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_backoff.retry_next_cursors[backoff_index]);
        debugWrite(" wait ");
        debugWriteU64Decimal(network.ntp_backoff.retry_wait_ticks[backoff_index]);
    }
    debugWrite(", timeout delta/state/reached/cancelled/exhausted ");
    debugWriteU64Decimal(network.ntp_backoff.timeout_tick_delta);
    debugWrite("/");
    debugWriteNtpServiceState(network.ntp_backoff.timeout_state);
    debugWrite("/");
    debugWrite(if (network.ntp_backoff.timeout_reached) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_backoff.request_cancelled) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_backoff.retry_exhausted) "yes" else "no");
    debugWrite(", latched/health ");
    debugWrite(if (network.ntp_backoff.timeout_latched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_backoff.health_reports_exhaustion) "yes" else "no");
    debugWrite(", clear/duplicate ");
    debugWrite(if (network.ntp_backoff.clear_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_backoff.duplicate_clear_rejected) "yes" else "no");
    debugWrite(", restart ");
    debugWriteU64Decimal(network.ntp_backoff.restart_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.restart_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.restart_next_cursor);
    debugWrite(" wait ");
    debugWriteU64Decimal(network.ntp_backoff.restart_wait_ticks);
    debugWrite(", close ");
    debugWrite(if (network.ntp_backoff.close_succeeded) "yes" else "no");
    debugWrite(", counts ");
    debugWriteU64Decimal(network.ntp_backoff.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.retry_limit_hits);
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_backoff.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_backoff.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_backoff.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_backoff.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_backoff.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_backoff.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_backoff.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP automatic recovery verified: source ");
    debugWriteReferenceKind(network.ntp_automatic_recovery.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.counter_bits);
    debugWrite(", invalid policy/state preserved ");
    debugWrite(if (network.ntp_automatic_recovery.invalid_policy_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_automatic_recovery.invalid_policy_state_preserved) "yes" else "no");
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.local_port);
    debugWrite(", retry ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.retry_initial_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.retry_maximum_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.retry_maximum_retries);
    debugWrite(" recovery ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.recovery_cooldown_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.recovery_maximum_recoveries);
    debugWrite(", transmissions ");
    var recovery_tx_index: usize = 0;
    while (recovery_tx_index < network.ntp_automatic_recovery.transmit_identifications.len) : (recovery_tx_index += 1) {
        if (recovery_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_automatic_recovery.transmit_identifications[recovery_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_automatic_recovery.transmit_descriptors[recovery_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_automatic_recovery.transmit_next_cursors[recovery_tx_index]);
    }
    debugWrite(", timeline first ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.first_timeout_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.first_recovery_deadline_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.first_recovery_delta);
    debugWrite(" second ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.second_timeout_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.second_recovery_deadline_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.second_recovery_delta);
    debugWrite(" terminal ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.terminal_timeout_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.terminal_recovery_deadline_delta);
    debugWrite(", waits no-TX ");
    debugWrite(if (network.ntp_automatic_recovery.first_wait_no_tx) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_automatic_recovery.second_wait_no_tx) "yes" else "no");
    debugWrite(", recovery starts ");
    debugWrite(if (network.ntp_automatic_recovery.first_recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_automatic_recovery.second_recovery_started) "yes" else "no");
    debugWrite(", exhausted/latched/health/bootstrap ");
    debugWrite(if (network.ntp_automatic_recovery.terminal_exhausted) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_automatic_recovery.timeout_latched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_automatic_recovery.health_reports_exhaustion) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_automatic_recovery.bootstrap_timestamp_preserved) "yes" else "no");
    debugWrite(", counts ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.automatic_recoveries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.recovery_limit_hits);
    debugWrite(", close ");
    debugWrite(if (network.ntp_automatic_recovery.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_automatic_recovery.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_automatic_recovery.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP synchronized recovery verified: source ");
    debugWriteReferenceKind(network.ntp_synchronized_recovery.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.local_port);
    debugWrite(", transmissions ");
    var synchronized_recovery_tx_index: usize = 0;
    while (synchronized_recovery_tx_index < network.ntp_synchronized_recovery.transmit_identifications.len) : (synchronized_recovery_tx_index += 1) {
        if (synchronized_recovery_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_synchronized_recovery.transmit_identifications[synchronized_recovery_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_synchronized_recovery.transmit_descriptors[synchronized_recovery_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_synchronized_recovery.transmit_next_cursors[synchronized_recovery_tx_index]);
    }
    debugWrite(", timestamps initial/refresh/recovery1/recovery2 0x");
    debugWriteHex64(network.ntp_synchronized_recovery.initial_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_synchronized_recovery.refresh_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_synchronized_recovery.first_recovery_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_synchronized_recovery.second_recovery_client_timestamp);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_synchronized_recovery.first_refresh_timestamp_automatic) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_synchronized_recovery.first_recovery_timestamp_automatic) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_synchronized_recovery.second_recovery_timestamp_automatic) "yes" else "no");
    debugWrite(", holdover states ");
    debugWriteNtpHealth(network.ntp_synchronized_recovery.timeout_health_state);
    debugWrite("/");
    debugWriteNtpHealth(network.ntp_synchronized_recovery.cooldown_health_state);
    debugWrite(" timestamps 0x");
    debugWriteHex64(network.ntp_synchronized_recovery.timeout_health_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_synchronized_recovery.cooldown_health_timestamp);
    debugWrite(" visible/advanced ");
    debugWrite(if (network.ntp_synchronized_recovery.holdover_visible) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_synchronized_recovery.holdover_advanced) "yes" else "no");
    debugWrite(", first timeline ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.first_timeout_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.first_recovery_deadline_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.first_recovery_delta);
    debugWrite(" started ");
    debugWrite(if (network.ntp_synchronized_recovery.first_recovery_started) "yes" else "no");
    debugWrite(", accepted/successes/reset/advanced ");
    debugWrite(if (network.ntp_synchronized_recovery.recovery_response_accepted) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.recovery_successes_after_accept);
    debugWrite("/");
    debugWrite(if (network.ntp_synchronized_recovery.recovery_budget_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_synchronized_recovery.recovered_time_advanced) "yes" else "no");
    debugWrite(" recovered 0x");
    debugWriteHex64(network.ntp_synchronized_recovery.recovered_timestamp);
    debugWrite(", second timeline ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.second_timeout_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.second_recovery_deadline_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.second_recovery_delta);
    debugWrite(" started/budget/health ");
    debugWrite(if (network.ntp_synchronized_recovery.second_recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_synchronized_recovery.full_budget_restored) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_synchronized_recovery.health_reports_success) "yes" else "no");
    debugWrite(", counts ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.recovery_successes);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.automatic_recoveries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.recovery_limit_hits);
    debugWrite(", close ");
    debugWrite(if (network.ntp_synchronized_recovery.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_synchronized_recovery.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP live step gate verified: source ");
    debugWriteReferenceKind(network.ntp_live_step_gate.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_live_step_gate.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.counter_bits);
    debugWrite(", invalid policy/state preserved ");
    debugWrite(if (network.ntp_live_step_gate.invalid_policy_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_step_gate.invalid_policy_state_preserved) "yes" else "no");
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_live_step_gate.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.local_port);
    debugWrite(", policy ");
    debugWriteU64Decimal(network.ntp_live_step_gate.maximum_forward_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_live_step_gate.maximum_forward_fraction);
    debugWrite(", initial TX ");
    debugWriteU64Decimal(network.ntp_live_step_gate.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.initial_next_cursor);
    debugWrite(" results ");
    debugWriteNtpQuality(network.ntp_live_step_gate.initial_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_live_step_gate.initial_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_live_step_gate.first_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.first_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_live_step_gate.first_fraction);
    debugWrite(", refresh TX ");
    debugWriteU64Decimal(network.ntp_live_step_gate.refresh_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.refresh_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.refresh_next_cursor);
    debugWrite(" timestamp 0x");
    debugWriteHex64(network.ntp_live_step_gate.refresh_client_timestamp);
    debugWrite(", excessive ");
    debugWriteNtpQuality(network.ntp_live_step_gate.excessive_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_live_step_gate.excessive_step_result);
    debugWrite(" sample ");
    debugWriteU64Decimal(network.ntp_live_step_gate.excessive_sample_tick);
    debugWrite(" apply-absent/clock-preserved/request-retained ");
    debugWrite(if (network.ntp_live_step_gate.excessive_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_step_gate.excessive_clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_step_gate.excessive_request_retained) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_live_step_gate.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_live_step_gate.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_live_step_gate.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_live_step_gate.accepted_fraction);
    debugWrite(" advanced ");
    debugWrite(if (network.ntp_live_step_gate.final_clock_advanced) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_live_step_gate.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_live_step_gate.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.step_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.step_invalid_policy_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.step_stale_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.step_excessive_forward_rejected);
    debugWrite(" responses ");
    debugWriteU64Decimal(network.ntp_live_step_gate.responses);
    debugWrite(", close ");
    debugWrite(if (network.ntp_live_step_gate.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_live_step_gate.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_live_step_gate.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_live_step_gate.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_live_step_gate.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_live_step_gate.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_live_step_gate.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_step_gate.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP stale-step retry verified: source ");
    debugWriteReferenceKind(network.ntp_stale_step_retry.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.local_port);
    debugWrite(", policy ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.maximum_forward_seconds);
    debugWrite(", initial TX ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.initial_next_cursor);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.first_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.first_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_stale_step_retry.first_fraction);
    debugWrite(", refresh TX ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.refresh_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.refresh_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.refresh_next_cursor);
    debugWrite(" timestamp 0x");
    debugWriteHex64(network.ntp_stale_step_retry.refresh_client_timestamp);
    debugWrite(", stale ");
    debugWriteNtpQuality(network.ntp_stale_step_retry.stale_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_stale_step_retry.stale_step_result);
    debugWrite(" sample ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.stale_sample_tick);
    debugWrite(" apply-absent/clock-preserved/request-retained ");
    debugWrite(if (network.ntp_stale_step_retry.stale_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_stale_step_retry.stale_clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_stale_step_retry.stale_request_retained) "yes" else "no");
    debugWrite(", retry ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.retry_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.retry_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.retry_next_cursor);
    debugWrite(" timestamp-preserved/transmissions ");
    debugWrite(if (network.ntp_stale_step_retry.retry_timestamp_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.retry_transmissions);
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_stale_step_retry.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_stale_step_retry.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_stale_step_retry.accepted_fraction);
    debugWrite(" advanced ");
    debugWrite(if (network.ntp_stale_step_retry.final_clock_advanced) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.step_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.step_invalid_policy_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.step_stale_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.step_excessive_forward_rejected);
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.responses);
    debugWrite(", close ");
    debugWrite(if (network.ntp_stale_step_retry.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_stale_step_retry.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_step_retry.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP live rejection budget verified: source ");
    debugWriteReferenceKind(network.ntp_live_rejection_budget.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.counter_bits);
    debugWrite(", invalid policy/state preserved ");
    debugWrite(if (network.ntp_live_rejection_budget.invalid_policy_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_rejection_budget.invalid_policy_state_preserved) "yes" else "no");
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.local_port);
    debugWrite(", max ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.maximum_rejections);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.initial_next_cursor);
    debugWrite(" sample ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.first_sample_tick);
    debugWrite(", refresh ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.refresh_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.refresh_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.refresh_next_cursor);
    debugWrite(" timestamp 0x");
    debugWriteHex64(network.ntp_live_rejection_budget.refresh_client_timestamp);
    debugWrite(", first ");
    debugWriteNtpQuality(network.ntp_live_rejection_budget.first_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_live_rejection_budget.first_step_result);
    debugWrite("/");
    debugWriteNtpStepRejectionAction(network.ntp_live_rejection_budget.first_rejection_action);
    debugWrite(" count/remaining ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.first_rejection_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.first_remaining);
    debugWrite(" absent/preserved/retained ");
    debugWrite(if (network.ntp_live_rejection_budget.first_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_rejection_budget.first_clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_rejection_budget.first_request_retained) "yes" else "no");
    debugWrite(", boundary ");
    debugWriteNtpQuality(network.ntp_live_rejection_budget.boundary_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_live_rejection_budget.boundary_step_result);
    debugWrite("/");
    debugWriteNtpStepRejectionAction(network.ntp_live_rejection_budget.boundary_rejection_action);
    debugWrite(" count/remaining ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.boundary_rejection_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.boundary_remaining);
    debugWrite(" absent/preserved ");
    debugWrite(if (network.ntp_live_rejection_budget.boundary_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_rejection_budget.boundary_clock_preserved) "yes" else "no");
    debugWrite(", forced retry ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.forced_retry_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.forced_retry_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.forced_retry_next_cursor);
    debugWrite(" before-deadline/timestamp-preserved/transmissions/reset ");
    debugWrite(if (network.ntp_live_rejection_budget.forced_retry_before_deadline) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_rejection_budget.forced_retry_timestamp_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.forced_retry_transmissions);
    debugWrite("/");
    debugWrite(if (network.ntp_live_rejection_budget.rejection_count_reset) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_live_rejection_budget.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_live_rejection_budget.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_live_rejection_budget.accepted_fraction);
    debugWrite(" advanced ");
    debugWrite(if (network.ntp_live_rejection_budget.final_clock_advanced) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.step_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.step_stale_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.step_excessive_forward_rejected);
    debugWrite(" forced/lifecycle ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.discipline_forced_retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.responses);
    debugWrite(", close ");
    debugWrite(if (network.ntp_live_rejection_budget.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_rejection_budget.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP rejection exhaustion verified: source ");
    debugWriteReferenceKind(network.ntp_rejection_exhaustion.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.local_port);
    debugWrite(", policies reject/retry ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.maximum_rejections);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.maximum_retries);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.initial_next_cursor);
    debugWrite(", refresh ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.refresh_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.refresh_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.refresh_next_cursor);
    debugWrite(" timestamp 0x");
    debugWriteHex64(network.ntp_rejection_exhaustion.refresh_client_timestamp);
    debugWrite(", first ");
    debugWriteNtpQuality(network.ntp_rejection_exhaustion.first_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_rejection_exhaustion.first_step_result);
    debugWrite("/");
    debugWriteNtpStepRejectionAction(network.ntp_rejection_exhaustion.first_rejection_action);
    debugWrite(" retry ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.first_forced_retry_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.first_forced_retry_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.first_forced_retry_next_cursor);
    debugWrite(" timestamp-preserved/transmissions ");
    debugWrite(if (network.ntp_rejection_exhaustion.first_forced_retry_timestamp_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.first_forced_retry_transmissions);
    debugWrite(", second ");
    debugWriteNtpQuality(network.ntp_rejection_exhaustion.second_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_rejection_exhaustion.second_step_result);
    debugWrite("/");
    debugWriteNtpStepRejectionAction(network.ntp_rejection_exhaustion.second_rejection_action);
    debugWrite(" count/remaining ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.second_rejection_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.second_remaining);
    debugWrite(" absent/preserved ");
    debugWrite(if (network.ntp_rejection_exhaustion.second_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejection_exhaustion.second_clock_preserved) "yes" else "no");
    debugWrite(", timeout ");
    debugWriteNtpServiceState(network.ntp_rejection_exhaustion.timeout_state);
    debugWrite(" reached/no-TX/cancelled/inactive/exhausted ");
    debugWrite(if (network.ntp_rejection_exhaustion.timeout_reached) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejection_exhaustion.timeout_transmit_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejection_exhaustion.request_cancelled) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejection_exhaustion.request_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejection_exhaustion.retry_exhausted) "yes" else "no");
    debugWrite(" limit/forced ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.discipline_forced_retries);
    debugWrite(", latched/health ");
    debugWrite(if (network.ntp_rejection_exhaustion.timeout_latched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejection_exhaustion.health_reports_exhaustion) "yes" else "no");
    debugWrite(", clear/duplicate/count-cleared ");
    debugWrite(if (network.ntp_rejection_exhaustion.clear_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejection_exhaustion.duplicate_clear_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejection_exhaustion.rejection_count_cleared) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.step_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.step_stale_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.step_excessive_forward_rejected);
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.responses);
    debugWrite(", close ");
    debugWrite(if (network.ntp_rejection_exhaustion.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejection_exhaustion.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP discipline recovery verified: source ");
    debugWriteReferenceKind(network.ntp_discipline_recovery.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.local_port);
    debugWrite(", policies reject/retry/recovery ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.maximum_rejections);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.maximum_retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.recovery_cooldown_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.maximum_recoveries);
    debugWrite(", transmissions ");
    var discipline_recovery_index: usize = 0;
    while (discipline_recovery_index < network.ntp_discipline_recovery.transmit_identifications.len) : (discipline_recovery_index += 1) {
        if (discipline_recovery_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_discipline_recovery.transmit_identifications[discipline_recovery_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_discipline_recovery.transmit_descriptors[discipline_recovery_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_discipline_recovery.transmit_next_cursors[discipline_recovery_index]);
    }
    debugWrite(", timestamps refresh/recovery 0x");
    debugWriteHex64(network.ntp_discipline_recovery.refresh_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_discipline_recovery.recovery_client_timestamp);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_discipline_recovery.recovery_timestamp_automatic) "yes" else "no");
    debugWrite(", timeout ");
    debugWriteNtpServiceState(network.ntp_discipline_recovery.timeout_state);
    debugWrite(" waiting/no-TX/cancelled/exhausted ");
    debugWrite(if (network.ntp_discipline_recovery.timeout_waiting) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.timeout_transmit_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.request_cancelled) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.retry_exhausted) "yes" else "no");
    debugWrite(" deadline ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.recovery_deadline_delta);
    debugWrite(", holdover states ");
    debugWriteNtpHealth(network.ntp_discipline_recovery.timeout_health_state);
    debugWrite("/");
    debugWriteNtpHealth(network.ntp_discipline_recovery.cooldown_health_state);
    debugWrite(" timestamps 0x");
    debugWriteHex64(network.ntp_discipline_recovery.timeout_health_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_discipline_recovery.cooldown_health_timestamp);
    debugWrite(" visible/advanced ");
    debugWrite(if (network.ntp_discipline_recovery.holdover_visible) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.holdover_advanced) "yes" else "no");
    debugWrite(", cooldown no-TX ");
    debugWrite(if (network.ntp_discipline_recovery.cooldown_no_tx) "yes" else "no");
    debugWrite(", recovery ready/started ");
    debugWrite(if (network.ntp_discipline_recovery.recovery_ready) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.recovery_started) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_discipline_recovery.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_discipline_recovery.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_discipline_recovery.accepted_fraction);
    debugWrite(", reset successes/recovery/retry/rejection/clock/health ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.recovery_successes);
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.recovery_budget_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.retry_budget_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.rejection_budget_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.clock_advanced) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_discipline_recovery.health_reports_success) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.step_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.step_stale_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.step_excessive_forward_rejected);
    debugWrite(" forced/lifecycle ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.discipline_forced_retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.responses);
    debugWrite(", close ");
    debugWrite(if (network.ntp_discipline_recovery.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_discipline_recovery.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discipline_recovery.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP live quality rejection budget verified: source ");
    debugWriteReferenceKind(network.ntp_live_quality_rejection_budget.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.counter_bits);
    debugWrite(", invalid policy/state preserved ");
    debugWrite(if (network.ntp_live_quality_rejection_budget.invalid_policy_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_quality_rejection_budget.invalid_policy_state_preserved) "yes" else "no");
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.local_port);
    debugWrite(", max ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.maximum_rejections);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.initial_next_cursor);
    debugWrite(" timestamp 0x");
    debugWriteHex64(network.ntp_live_quality_rejection_budget.client_timestamp);
    debugWrite(", first ");
    debugWriteNtpQuality(network.ntp_live_quality_rejection_budget.first_quality_result);
    debugWrite(" retain count/remaining ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.first_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.first_remaining);
    debugWrite(" sample/apply absent clock/request preserved ");
    debugWrite(if (network.ntp_live_quality_rejection_budget.first_sample_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_quality_rejection_budget.first_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_quality_rejection_budget.first_clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_quality_rejection_budget.first_request_retained) "yes" else "no");
    debugWrite(", boundary ");
    debugWriteNtpQuality(network.ntp_live_quality_rejection_budget.boundary_quality_result);
    debugWrite(" retry-now count/remaining ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.boundary_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.boundary_remaining);
    debugWrite(" sample/apply absent clock preserved ");
    debugWrite(if (network.ntp_live_quality_rejection_budget.boundary_sample_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_quality_rejection_budget.boundary_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_quality_rejection_budget.boundary_clock_preserved) "yes" else "no");
    debugWrite(", forced retry ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.forced_retry_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.forced_retry_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.forced_retry_next_cursor);
    debugWrite(" before-deadline/timestamp-preserved/transmissions/reset ");
    debugWrite(if (network.ntp_live_quality_rejection_budget.forced_retry_before_deadline) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_quality_rejection_budget.forced_retry_timestamp_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.forced_retry_transmissions);
    debugWrite("/");
    debugWrite(if (network.ntp_live_quality_rejection_budget.quality_count_reset) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_live_quality_rejection_budget.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_live_quality_rejection_budget.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_live_quality_rejection_budget.accepted_fraction);
    debugWrite(" health ");
    debugWrite(if (network.ntp_live_quality_rejection_budget.health_reports_policy) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.quality_rejected);
    debugWrite(" reasons stratum/dispersion ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.quality_stratum_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.quality_root_dispersion_rejected);
    debugWrite(" forced/step/lifecycle ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.quality_forced_retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.responses);
    debugWrite(", close ");
    debugWrite(if (network.ntp_live_quality_rejection_budget.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_quality_rejection_budget.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP quality rejection exhaustion verified: source ");
    debugWriteReferenceKind(network.ntp_quality_rejection_exhaustion.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.local_port);
    debugWrite(", policies reject/retry ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.maximum_rejections);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.maximum_retries);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.initial_next_cursor);
    debugWrite(" timestamp 0x");
    debugWriteHex64(network.ntp_quality_rejection_exhaustion.client_timestamp);
    debugWrite(", first ");
    debugWriteNtpQuality(network.ntp_quality_rejection_exhaustion.first_quality_result);
    debugWrite(" retry-now sample/apply absent clock preserved ");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.first_sample_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.first_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.first_clock_preserved) "yes" else "no");
    debugWrite(" retry ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.forced_retry_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.forced_retry_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.forced_retry_next_cursor);
    debugWrite(" timestamp-preserved/transmissions ");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.forced_retry_timestamp_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.forced_retry_transmissions);
    debugWrite(", second ");
    debugWriteNtpQuality(network.ntp_quality_rejection_exhaustion.second_quality_result);
    debugWrite(" retry-now count/remaining ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.second_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.second_remaining);
    debugWrite(" sample/apply absent clock preserved ");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.second_sample_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.second_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.second_clock_preserved) "yes" else "no");
    debugWrite(", timeout ");
    debugWriteNtpServiceState(network.ntp_quality_rejection_exhaustion.timeout_state);
    debugWrite(" reached/no-TX/cancelled/inactive/exhausted ");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.timeout_reached) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.timeout_transmit_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.request_cancelled) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.request_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.retry_exhausted) "yes" else "no");
    debugWrite(" limit/forced ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.quality_forced_retries);
    debugWrite(", latched/health ");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.timeout_latched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.health_reports_exhaustion) "yes" else "no");
    debugWrite(", clear/duplicate/count-cleared ");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.clear_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.duplicate_clear_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.rejection_count_cleared) "yes" else "no");
    debugWrite(", restart ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.restart_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.restart_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.restart_next_cursor);
    debugWrite(" wait ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.restart_wait_ticks);
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.quality_rejected);
    debugWrite(" reasons stratum/dispersion ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.quality_stratum_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.quality_root_dispersion_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.step_rejected);
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.responses);
    debugWrite(", close ");
    debugWrite(if (network.ntp_quality_rejection_exhaustion.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_exhaustion.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP quality recovery verified: source ");
    debugWriteReferenceKind(network.ntp_quality_recovery.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_quality_recovery.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_quality_recovery.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.local_port);
    debugWrite(", policies quality/retry/recovery ");
    debugWriteU64Decimal(network.ntp_quality_recovery.maximum_quality_rejections);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.maximum_retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.recovery_cooldown_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.maximum_recoveries);
    debugWrite(", transmissions ");
    var quality_recovery_index: usize = 0;
    while (quality_recovery_index < network.ntp_quality_recovery.transmit_identifications.len) : (quality_recovery_index += 1) {
        if (quality_recovery_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_quality_recovery.transmit_identifications[quality_recovery_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_quality_recovery.transmit_descriptors[quality_recovery_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_quality_recovery.transmit_next_cursors[quality_recovery_index]);
    }
    debugWrite(", timestamps refresh/recovery 0x");
    debugWriteHex64(network.ntp_quality_recovery.refresh_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_quality_recovery.recovery_client_timestamp);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_quality_recovery.recovery_timestamp_automatic) "yes" else "no");
    debugWrite(", rejections ");
    debugWriteNtpQuality(network.ntp_quality_recovery.first_quality_result);
    debugWrite("/");
    debugWriteNtpQuality(network.ntp_quality_recovery.second_quality_result);
    debugWrite(" no-sample/apply/clock ");
    debugWrite(if (network.ntp_quality_recovery.first_sample_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.first_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.first_clock_preserved) "yes" else "no");
    debugWrite(" -> ");
    debugWrite(if (network.ntp_quality_recovery.second_sample_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.second_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.second_clock_preserved) "yes" else "no");
    debugWrite(", first retry timestamp/transmissions ");
    debugWrite(if (network.ntp_quality_recovery.first_retry_timestamp_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.first_retry_transmissions);
    debugWrite(", timeout ");
    debugWriteNtpServiceState(network.ntp_quality_recovery.timeout_state);
    debugWrite(" waiting/no-TX/cancelled/exhausted ");
    debugWrite(if (network.ntp_quality_recovery.timeout_waiting) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.timeout_transmit_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.request_cancelled) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.retry_exhausted) "yes" else "no");
    debugWrite(" deadline ");
    debugWriteU64Decimal(network.ntp_quality_recovery.recovery_deadline_delta);
    debugWrite(", holdover states ");
    debugWriteNtpHealth(network.ntp_quality_recovery.timeout_health_state);
    debugWrite("/");
    debugWriteNtpHealth(network.ntp_quality_recovery.cooldown_health_state);
    debugWrite(" timestamps 0x");
    debugWriteHex64(network.ntp_quality_recovery.timeout_health_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_quality_recovery.cooldown_health_timestamp);
    debugWrite(" visible/advanced ");
    debugWrite(if (network.ntp_quality_recovery.holdover_visible) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.holdover_advanced) "yes" else "no");
    debugWrite(", cooldown no-TX ");
    debugWrite(if (network.ntp_quality_recovery.cooldown_no_tx) "yes" else "no");
    debugWrite(", recovery ready/started ");
    debugWrite(if (network.ntp_quality_recovery.recovery_ready) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.recovery_started) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_quality_recovery.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_quality_recovery.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_quality_recovery.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_quality_recovery.accepted_fraction);
    debugWrite(", reset successes/recovery/retry/quality/step/clock/health ");
    debugWriteU64Decimal(network.ntp_quality_recovery.recovery_successes);
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.recovery_budget_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.retry_budget_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.quality_budget_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.step_budget_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.clock_advanced) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_recovery.health_reports_success) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_quality_recovery.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.quality_rejected);
    debugWrite(" reasons stratum/dispersion ");
    debugWriteU64Decimal(network.ntp_quality_recovery.quality_stratum_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.quality_root_dispersion_rejected);
    debugWrite(" forced/step/lifecycle/limit ");
    debugWriteU64Decimal(network.ntp_quality_recovery.quality_forced_retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.step_rejected);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.retry_limit_hits);
    debugWrite(", close ");
    debugWrite(if (network.ntp_quality_recovery.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_quality_recovery.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_quality_recovery.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_quality_recovery.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.rx_completion_enqueues);
    debugWrite(", endpoints/cursor ");
    debugWriteU64Decimal(network.ntp_quality_recovery.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.final_ephemeral_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_quality_recovery.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_quality_recovery.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_recovery.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP client server switch verified: socket ");
    debugWriteU64Decimal(network.ntp_client_server_switch.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.local_port);
    debugWrite(", servers ");
    debugWriteIpv4(network.ntp_client_server_switch.original_server);
    debugWrite(" -> ");
    debugWriteIpv4(network.ntp_client_server_switch.alternate_server);
    debugWrite(" -> ");
    debugWriteIpv4(network.ntp_client_server_switch.original_server);
    debugWrite(", invalid/idempotent/forward/reverse ");
    debugWrite(if (network.ntp_client_server_switch.invalid_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.idempotent_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.forward_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.reverse_succeeded) "yes" else "no");
    debugWrite(", state invalid/idempotent/forward/reverse ");
    debugWrite(if (network.ntp_client_server_switch.invalid_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.idempotent_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.forward_peer_updated) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.reverse_peer_restored) "yes" else "no");
    debugWrite(", socket/MAC/port preserved ");
    debugWrite(if (network.ntp_client_server_switch.socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.gateway_mac_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.peer_port);
    debugWrite(", close/inactive/stale ");
    debugWrite(if (network.ntp_client_server_switch.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.inactive_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.stale_rejected) "yes" else "no");
    debugWrite(" state ");
    debugWrite(if (network.ntp_client_server_switch.inactive_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_client_server_switch.stale_state_preserved) "yes" else "no");
    debugWrite(", no traffic ");
    debugWrite(if (network.ntp_client_server_switch.no_packet_traffic) "yes" else "no");
    debugWrite(", final endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_client_server_switch.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.final_generation_cursor);
    debugWrite(", IP/TX ");
    debugWriteU64Decimal(network.ntp_client_server_switch.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.final_tx_cursor);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_client_server_switch.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.rx_completion_enqueues);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_client_server_switch.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_client_server_switch.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_client_server_switch.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP service source pool verified: invalid pool/state ");
    debugWrite(if (network.ntp_service_source_pool.invalid_pool_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_source_pool.invalid_pool_state_preserved) "yes" else "no");
    debugWrite(", mismatch/state ");
    debugWrite(if (network.ntp_service_source_pool.mismatched_policy_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_source_pool.mismatched_policy_state_preserved) "yes" else "no");
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_service_source_pool.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.local_port);
    debugWrite(", pool/threshold ");
    debugWriteU64Decimal(network.ntp_service_source_pool.pool_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.rotation_threshold);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_service_source_pool.first_server);
    debugWrite("/");
    debugWriteIpv4(network.ntp_service_source_pool.second_server);
    debugWrite(", client/peer/state ");
    debugWrite(if (network.ntp_service_source_pool.client_server_matches_first) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_source_pool.peer_matches_first) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_source_pool.source_state_initialized) "yes" else "no");
    debugWrite(", health pool/policy/source/failures/rotations ");
    debugWrite(if (network.ntp_service_source_pool.health_reports_pool) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_source_pool.health_reports_policy) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_source_pool.health_reports_current_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_source_pool.health_reports_failure_count) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_source_pool.health_reports_rotations) "yes" else "no");
    debugWrite(", close/no-traffic ");
    debugWrite(if (network.ntp_service_source_pool.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_source_pool.no_packet_traffic) "yes" else "no");
    debugWrite(", final endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_service_source_pool.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.final_generation_cursor);
    debugWrite(", IP/TX ");
    debugWriteU64Decimal(network.ntp_service_source_pool.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.final_tx_cursor);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_service_source_pool.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.rx_completion_enqueues);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_service_source_pool.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_service_source_pool.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_source_pool.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP live source failover verified: source ");
    debugWriteReferenceKind(network.ntp_live_source_failover.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_live_source_failover.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_live_source_failover.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.local_port);
    debugWrite(", pool/threshold ");
    debugWriteU64Decimal(network.ntp_live_source_failover.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.failures_before_rotation);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_live_source_failover.first_server);
    debugWrite("->");
    debugWriteIpv4(network.ntp_live_source_failover.second_server);
    debugWrite(", transmissions ");
    var source_failover_index: usize = 0;
    while (source_failover_index < network.ntp_live_source_failover.transmit_identifications.len) : (source_failover_index += 1) {
        if (source_failover_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_live_source_failover.transmit_identifications[source_failover_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_live_source_failover.transmit_descriptors[source_failover_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_live_source_failover.transmit_next_cursors[source_failover_index]);
    }
    debugWrite(", timestamps refresh/recovery 0x");
    debugWriteHex64(network.ntp_live_source_failover.refresh_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_live_source_failover.recovery_client_timestamp);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_live_source_failover.recovery_timestamp_automatic) "yes" else "no");
    debugWrite(", timeout ");
    debugWriteNtpServiceState(network.ntp_live_source_failover.timeout_state);
    debugWrite(" reached/no-TX/cancelled ");
    debugWrite(if (network.ntp_live_source_failover.timeout_reached) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_source_failover.timeout_transmit_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_source_failover.request_cancelled) "yes" else "no");
    debugWrite(" source/pending/failures ");
    debugWriteU64Decimal(network.ntp_live_source_failover.timeout_current_source);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.timeout_pending_source);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.timeout_failure_count);
    debugWrite(" server-preserved ");
    debugWrite(if (network.ntp_live_source_failover.timeout_server_preserved) "yes" else "no");
    debugWrite(" deadline ");
    debugWriteU64Decimal(network.ntp_live_source_failover.recovery_deadline_delta);
    debugWrite(", cooldown no-TX ");
    debugWrite(if (network.ntp_live_source_failover.cooldown_no_tx) "yes" else "no");
    debugWrite(", recovery ready/started/switched/socket ");
    debugWrite(if (network.ntp_live_source_failover.recovery_ready) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_source_failover.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_source_failover.source_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_source_failover.same_socket_preserved) "yes" else "no");
    debugWrite(" rotations/failure-reset/pending-clear ");
    debugWriteU64Decimal(network.ntp_live_source_failover.rotation_count);
    debugWrite("/");
    debugWrite(if (network.ntp_live_source_failover.failure_count_reset_on_switch) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_source_failover.pending_cleared_on_switch) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_live_source_failover.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_live_source_failover.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_live_source_failover.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_live_source_failover.accepted_fraction);
    debugWrite(" successes ");
    debugWriteU64Decimal(network.ntp_live_source_failover.recovery_successes);
    debugWrite(" health source/rotation/success ");
    debugWrite(if (network.ntp_live_source_failover.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_source_failover.health_reports_rotation) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_source_failover.health_reports_success) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_live_source_failover.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_live_source_failover.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.step_rejected);
    debugWrite(" lifecycle/limit ");
    debugWriteU64Decimal(network.ntp_live_source_failover.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.retry_limit_hits);
    debugWrite(", close ");
    debugWrite(if (network.ntp_live_source_failover.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_live_source_failover.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_live_source_failover.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_live_source_failover.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_live_source_failover.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_live_source_failover.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_live_source_failover.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_source_failover.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP thresholded source failover verified: source ");
    debugWriteReferenceKind(network.ntp_thresholded_source_failover.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.local_port);
    debugWrite(", pool/threshold ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.failures_before_rotation);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_thresholded_source_failover.first_server);
    debugWrite("->");
    debugWriteIpv4(network.ntp_thresholded_source_failover.second_server);
    debugWrite(", transmissions ");
    var thresholded_failover_index: usize = 0;
    while (thresholded_failover_index < network.ntp_thresholded_source_failover.transmit_identifications.len) : (thresholded_failover_index += 1) {
        if (thresholded_failover_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_thresholded_source_failover.transmit_identifications[thresholded_failover_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_thresholded_source_failover.transmit_descriptors[thresholded_failover_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_thresholded_source_failover.transmit_next_cursors[thresholded_failover_index]);
    }
    debugWrite(", timestamps refresh/recovery1/recovery2 0x");
    debugWriteHex64(network.ntp_thresholded_source_failover.refresh_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_thresholded_source_failover.first_recovery_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_thresholded_source_failover.second_recovery_client_timestamp);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_thresholded_source_failover.recovery_timestamps_automatic) "yes" else "no");
    debugWrite(", first timeout ");
    debugWriteNtpServiceState(network.ntp_thresholded_source_failover.first_timeout_state);
    debugWrite(" pending-absent/failures/server ");
    debugWrite(if (network.ntp_thresholded_source_failover.first_timeout_pending_absent) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.first_timeout_failure_count);
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.first_timeout_server_preserved) "yes" else "no");
    debugWrite(", first recovery same/no-rotation/failure/start ");
    debugWrite(if (network.ntp_thresholded_source_failover.first_recovery_same_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.first_recovery_no_rotation) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.first_recovery_failure_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.first_recovery_started) "yes" else "no");
    debugWrite(", second timeout ");
    debugWriteNtpServiceState(network.ntp_thresholded_source_failover.second_timeout_state);
    debugWrite(" pending/failures/server ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.second_timeout_pending_source);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.second_timeout_failure_count);
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.second_timeout_server_preserved) "yes" else "no");
    debugWrite(", cooldowns no-TX ");
    debugWrite(if (network.ntp_thresholded_source_failover.first_cooldown_no_tx) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.second_cooldown_no_tx) "yes" else "no");
    debugWrite(", second recovery ready/start/switch/socket ");
    debugWrite(if (network.ntp_thresholded_source_failover.second_recovery_ready) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.second_recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.second_recovery_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.same_socket_preserved) "yes" else "no");
    debugWrite(" rotations/reset ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.rotation_count);
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.source_state_reset_on_switch) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_thresholded_source_failover.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_thresholded_source_failover.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_thresholded_source_failover.accepted_fraction);
    debugWrite(" successes ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.recovery_successes);
    debugWrite(" health source/rotation/success ");
    debugWrite(if (network.ntp_thresholded_source_failover.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.health_reports_rotation) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_thresholded_source_failover.health_reports_success) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.step_rejected);
    debugWrite(" lifecycle/limit ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.retry_limit_hits);
    debugWrite(", close ");
    debugWrite(if (network.ntp_thresholded_source_failover.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_thresholded_source_failover.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP source wraparound verified: source ");
    debugWriteReferenceKind(network.ntp_source_wraparound.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_source_wraparound.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_source_wraparound.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.local_port);
    debugWrite(", pool/threshold ");
    debugWriteU64Decimal(network.ntp_source_wraparound.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.failures_before_rotation);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_source_wraparound.servers[0]);
    debugWrite("->");
    debugWriteIpv4(network.ntp_source_wraparound.servers[1]);
    debugWrite("->");
    debugWriteIpv4(network.ntp_source_wraparound.servers[2]);
    debugWrite("->");
    debugWriteIpv4(network.ntp_source_wraparound.servers[0]);
    debugWrite(", transmissions ");
    var source_wrap_tx_index: usize = 0;
    while (source_wrap_tx_index < network.ntp_source_wraparound.transmit_identifications.len) : (source_wrap_tx_index += 1) {
        if (source_wrap_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_source_wraparound.transmit_identifications[source_wrap_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_wraparound.transmit_descriptors[source_wrap_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_wraparound.transmit_next_cursors[source_wrap_tx_index]);
    }
    debugWrite(", timestamps refresh/recoveries 0x");
    debugWriteHex64(network.ntp_source_wraparound.refresh_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_source_wraparound.recovery_client_timestamps[0]);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_source_wraparound.recovery_client_timestamps[1]);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_source_wraparound.recovery_client_timestamps[2]);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_source_wraparound.recovery_timestamps_automatic) "yes" else "no");
    debugWrite(", timeouts current/pending/failures ");
    var source_wrap_timeout_index: usize = 0;
    while (source_wrap_timeout_index < network.ntp_source_wraparound.timeout_current_sources.len) : (source_wrap_timeout_index += 1) {
        if (source_wrap_timeout_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_source_wraparound.timeout_current_sources[source_wrap_timeout_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_wraparound.timeout_pending_sources[source_wrap_timeout_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_wraparound.timeout_failure_counts[source_wrap_timeout_index]);
    }
    debugWrite(" servers-preserved ");
    debugWrite(if (network.ntp_source_wraparound.timeout_servers_preserved) "yes" else "no");
    debugWrite(", cooldowns ");
    debugWrite(if (network.ntp_source_wraparound.cooldowns_no_tx[0]) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_wraparound.cooldowns_no_tx[1]) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_wraparound.cooldowns_no_tx[2]) "yes" else "no");
    debugWrite(", recoveries source/switch ");
    var source_wrap_recovery_index: usize = 0;
    while (source_wrap_recovery_index < network.ntp_source_wraparound.recovery_source_indices.len) : (source_wrap_recovery_index += 1) {
        if (source_wrap_recovery_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_source_wraparound.recovery_source_indices[source_wrap_recovery_index]);
        debugWrite("/");
        debugWrite(if (network.ntp_source_wraparound.recovery_switches_succeeded[source_wrap_recovery_index]) "yes" else "no");
    }
    debugWrite(" socket/rotations/wrap ");
    debugWrite(if (network.ntp_source_wraparound.same_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.rotation_count);
    debugWrite("/");
    debugWrite(if (network.ntp_source_wraparound.wrap_completed) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_source_wraparound.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_source_wraparound.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_source_wraparound.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_source_wraparound.accepted_fraction);
    debugWrite(" successes ");
    debugWriteU64Decimal(network.ntp_source_wraparound.recovery_successes);
    debugWrite(" health source/rotations/success ");
    debugWrite(if (network.ntp_source_wraparound.health_reports_source_zero) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_wraparound.health_reports_rotations) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_wraparound.health_reports_success) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_source_wraparound.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_source_wraparound.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.step_rejected);
    debugWrite(" lifecycle/limit ");
    debugWriteU64Decimal(network.ntp_source_wraparound.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.retry_limit_hits);
    debugWrite(", close ");
    debugWrite(if (network.ntp_source_wraparound.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_source_wraparound.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_source_wraparound.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_source_wraparound.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_source_wraparound.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_source_wraparound.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_source_wraparound.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_wraparound.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP source failure reset verified: source ");
    debugWriteReferenceKind(network.ntp_source_failure_reset.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.local_port);
    debugWrite(", pool/threshold ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.failures_before_rotation);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_source_failure_reset.server);
    debugWrite(", transmissions ");
    var source_reset_tx_index: usize = 0;
    while (source_reset_tx_index < network.ntp_source_failure_reset.transmit_identifications.len) : (source_reset_tx_index += 1) {
        if (source_reset_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_source_failure_reset.transmit_identifications[source_reset_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_failure_reset.transmit_descriptors[source_reset_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_failure_reset.transmit_next_cursors[source_reset_tx_index]);
    }
    debugWrite(", timestamps refresh/recovery ");
    debugWriteHex64(network.ntp_source_failure_reset.refresh_timestamps[0]);
    debugWrite("/");
    debugWriteHex64(network.ntp_source_failure_reset.recovery_timestamps[0]);
    debugWrite(" -> ");
    debugWriteHex64(network.ntp_source_failure_reset.refresh_timestamps[1]);
    debugWrite("/");
    debugWriteHex64(network.ntp_source_failure_reset.recovery_timestamps[1]);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_source_failure_reset.timestamps_automatic) "yes" else "no");
    debugWrite(", first timeout pending/failures/source/cooldown ");
    debugWrite(if (network.ntp_source_failure_reset.first_timeout_pending_absent) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.first_timeout_failure_count);
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.first_timeout_source_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.first_cooldown_no_tx) "yes" else "no");
    debugWrite(", first recovery same/start/accepted/reset/no-rotation/health ");
    debugWrite(if (network.ntp_source_failure_reset.first_recovery_same_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.first_recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.first_recovery_accepted) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.first_success_reset_failures) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.first_success_no_rotation) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.first_success_health_reset) "yes" else "no");
    debugWrite(", second timeout pending/failures/source/not-accumulated/cooldown ");
    debugWrite(if (network.ntp_source_failure_reset.second_timeout_pending_absent) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.second_timeout_failure_count);
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.second_timeout_source_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.second_timeout_not_accumulated) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.second_cooldown_no_tx) "yes" else "no");
    debugWrite(", second recovery same/start/accepted/reset/no-rotation/socket ");
    debugWrite(if (network.ntp_source_failure_reset.second_recovery_same_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.second_recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.second_recovery_accepted) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.final_failure_count_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.final_no_rotation) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.same_socket_preserved) "yes" else "no");
    debugWrite(", accepted times ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.accepted_seconds[0]);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_source_failure_reset.accepted_fractions[0]);
    debugWrite(" -> ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.accepted_seconds[1]);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_source_failure_reset.accepted_fractions[1]);
    debugWrite(" successes ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.recovery_successes);
    debugWrite(" health source/chain/success ");
    debugWrite(if (network.ntp_source_failure_reset.health_reports_source_zero) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.health_reports_clean_chain) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_failure_reset.health_reports_success) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.step_rejected);
    debugWrite(" lifecycle/limit ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.retry_limit_hits);
    debugWrite(", close ");
    debugWrite(if (network.ntp_source_failure_reset.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_source_failure_reset.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_failure_reset.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP source exhaustion verified: source ");
    debugWriteReferenceKind(network.ntp_source_exhaustion.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.local_port);
    debugWrite(", pool/threshold/recoveries ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.failures_before_rotation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.maximum_recoveries);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_source_exhaustion.servers[0]);
    debugWrite("->");
    debugWriteIpv4(network.ntp_source_exhaustion.servers[1]);
    debugWrite("->");
    debugWriteIpv4(network.ntp_source_exhaustion.servers[2]);
    debugWrite(", transmissions ");
    var source_exhaustion_tx_index: usize = 0;
    while (source_exhaustion_tx_index < network.ntp_source_exhaustion.transmit_identifications.len) : (source_exhaustion_tx_index += 1) {
        if (source_exhaustion_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_source_exhaustion.transmit_identifications[source_exhaustion_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_exhaustion.transmit_descriptors[source_exhaustion_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_exhaustion.transmit_next_cursors[source_exhaustion_tx_index]);
    }
    debugWrite(", timestamps refresh/recoveries 0x");
    debugWriteHex64(network.ntp_source_exhaustion.refresh_client_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_source_exhaustion.recovery_client_timestamps[0]);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_source_exhaustion.recovery_client_timestamps[1]);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_source_exhaustion.timestamps_automatic) "yes" else "no");
    debugWrite(", timeouts current/pending/failures ");
    var source_exhaustion_timeout_index: usize = 0;
    while (source_exhaustion_timeout_index < network.ntp_source_exhaustion.timeout_current_sources.len) : (source_exhaustion_timeout_index += 1) {
        if (source_exhaustion_timeout_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_source_exhaustion.timeout_current_sources[source_exhaustion_timeout_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_exhaustion.timeout_pending_sources[source_exhaustion_timeout_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_source_exhaustion.timeout_failure_counts[source_exhaustion_timeout_index]);
    }
    debugWrite(" first-two-waiting/cooldowns ");
    debugWrite(if (network.ntp_source_exhaustion.first_two_waiting) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.cooldowns_no_tx[0]) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.cooldowns_no_tx[1]) "yes" else "no");
    debugWrite(", recoveries source/switch ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.recovery_source_indices[0]);
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.recovery_switches_succeeded[0]) "yes" else "no");
    debugWrite(" -> ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.recovery_source_indices[1]);
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.recovery_switches_succeeded[1]) "yes" else "no");
    debugWrite(" socket/rotations ");
    debugWrite(if (network.ntp_source_exhaustion.same_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.rotation_count);
    debugWrite(", terminal ");
    debugWriteNtpServiceState(network.ntp_source_exhaustion.terminal_state);
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.terminal_recovery_state == .exhausted) "exhausted" else "other");
    debugWrite(" reached/no-TX/cancelled/retry/recovery ");
    debugWrite(if (network.ntp_source_exhaustion.terminal_timeout_reached) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.terminal_no_tx) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.terminal_request_cancelled) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.terminal_retry_exhausted) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.terminal_recovery_exhausted) "yes" else "no");
    debugWrite(" limit/deadline/source/pending/failures ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.terminal_recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.terminal_recovery_deadline_delta);
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.terminal_source_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.terminal_pending_wrap);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.terminal_failure_count);
    debugWrite(", repeated no-TX/latch ");
    debugWrite(if (network.ntp_source_exhaustion.repeated_exhausted_no_tx) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.repeated_latch_preserved) "yes" else "no");
    debugWrite(", holdover visible/advanced ");
    debugWrite(if (network.ntp_source_exhaustion.holdover_visible) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.holdover_advanced) "yes" else "no");
    debugWrite(" health source/exhaustion/holdover ");
    debugWrite(if (network.ntp_source_exhaustion.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.health_reports_exhaustion) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion.health_reports_holdover) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.step_rejected);
    debugWrite(" lifecycle/limit/success ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.recovery_successes);
    debugWrite(", close ");
    debugWrite(if (network.ntp_source_exhaustion.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_source_exhaustion.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP source exhaustion reset verified: source ");
    debugWriteReferenceKind(network.ntp_source_exhaustion_reset.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.local_port);
    debugWrite(", pool/source/server ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.current_source_index);
    debugWrite("/");
    debugWriteIpv4(network.ntp_source_exhaustion_reset.current_server);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.initial_next_cursor);
    debugWrite(", terminal/switch ");
    debugWrite(if (network.ntp_source_exhaustion_reset.terminal_seeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.switch_to_current_source_succeeded) "yes" else "no");
    debugWrite(", clear/duplicate/transient/cumulative/source/socket/clock ");
    debugWrite(if (network.ntp_source_exhaustion_reset.clear_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.duplicate_clear_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.transient_state_cleared) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.cumulative_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.source_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.clock_preserved) "yes" else "no");
    debugWrite(", refresh timestamp/TX 0x");
    debugWriteHex64(network.ntp_source_exhaustion_reset.projected_refresh_timestamp);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.refresh_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.refresh_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.refresh_next_cursor);
    debugWrite(" started/source ");
    debugWrite(if (network.ntp_source_exhaustion_reset.refresh_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.refresh_source_preserved) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_source_exhaustion_reset.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_source_exhaustion_reset.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_source_exhaustion_reset.accepted_fraction);
    debugWrite(" reset ");
    debugWrite(if (network.ntp_source_exhaustion_reset.accepted_reset_state) "yes" else "no");
    debugWrite(" health source/sync/cumulative ");
    debugWrite(if (network.ntp_source_exhaustion_reset.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.health_reports_synchronized) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_exhaustion_reset.health_preserves_cumulative) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.step_rejected);
    debugWrite(" lifecycle/limits/rotations ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.source_rotations);
    debugWrite(", close ");
    debugWrite(if (network.ntp_source_exhaustion_reset.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_exhaustion_reset.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP operator source reset verified: socket ");
    debugWriteU64Decimal(network.ntp_operator_source_reset.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.local_port);
    debugWrite(", pool/source ");
    debugWriteU64Decimal(network.ntp_operator_source_reset.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.original_source_index);
    debugWrite("->");
    debugWriteU64Decimal(network.ntp_operator_source_reset.target_source_index);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_operator_source_reset.original_server);
    debugWrite("->");
    debugWriteIpv4(network.ntp_operator_source_reset.target_server);
    debugWrite(", terminal ");
    debugWrite(if (network.ntp_operator_source_reset.terminal_seeded) "yes" else "no");
    debugWrite(", invalid rejected/state ");
    debugWrite(if (network.ntp_operator_source_reset.invalid_source_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_reset.invalid_state_preserved) "yes" else "no");
    debugWrite(", reset/socket/selected/transient/cumulative/rotations/duplicate ");
    debugWrite(if (network.ntp_operator_source_reset.reset_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_reset.same_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_reset.target_source_selected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_reset.transient_state_cleared) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_reset.cumulative_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_reset.rotations_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_reset.duplicate_reset_rejected) "yes" else "no");
    debugWrite(", no traffic/close ");
    debugWrite(if (network.ntp_operator_source_reset.no_packet_traffic) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_reset.close_succeeded) "yes" else "no");
    debugWrite(", final endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_operator_source_reset.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.final_generation_cursor);
    debugWrite(", IP/TX ");
    debugWriteU64Decimal(network.ntp_operator_source_reset.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.final_tx_cursor);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_operator_source_reset.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.rx_completion_enqueues);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_operator_source_reset.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_operator_source_reset.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_reset.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP operator source refresh verified: source ");
    debugWriteReferenceKind(network.ntp_operator_source_refresh.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.local_port);
    debugWrite(", reset ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.original_source_index);
    debugWrite("->");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.target_source_index);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_operator_source_refresh.original_server);
    debugWrite("->");
    debugWriteIpv4(network.ntp_operator_source_refresh.target_server);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.initial_next_cursor);
    debugWrite(", terminal/reset/socket/clock/transient/cumulative ");
    debugWrite(if (network.ntp_operator_source_refresh.terminal_seeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_refresh.reset_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_refresh.same_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_refresh.clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_refresh.transient_state_cleared) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_refresh.cumulative_state_preserved) "yes" else "no");
    debugWrite(", refresh timestamp/TX 0x");
    debugWriteHex64(network.ntp_operator_source_refresh.projected_refresh_timestamp);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.refresh_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.refresh_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.refresh_next_cursor);
    debugWrite(" started/source ");
    debugWrite(if (network.ntp_operator_source_refresh.refresh_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_refresh.refresh_target_source) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_operator_source_refresh.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_operator_source_refresh.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_operator_source_refresh.accepted_fraction);
    debugWrite(" clean ");
    debugWrite(if (network.ntp_operator_source_refresh.accepted_state_clean) "yes" else "no");
    debugWrite(" health source/sync/cumulative ");
    debugWrite(if (network.ntp_operator_source_refresh.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_refresh.health_reports_synchronized) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_refresh.health_preserves_cumulative) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.step_rejected);
    debugWrite(" lifecycle/limits/rotations ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.source_rotations);
    debugWrite(", close ");
    debugWrite(if (network.ntp_operator_source_refresh.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_refresh.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP operator failover verified: source ");
    debugWriteReferenceKind(network.ntp_operator_source_failover.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.local_port);
    debugWrite(", pool/manual/fallback ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.operator_source_index);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.fallback_source_index);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_operator_source_failover.operator_server);
    debugWrite("->");
    debugWriteIpv4(network.ntp_operator_source_failover.fallback_server);
    debugWrite(", transmissions ");
    var operator_failover_tx_index: usize = 0;
    while (operator_failover_tx_index < network.ntp_operator_source_failover.transmit_identifications.len) : (operator_failover_tx_index += 1) {
        if (operator_failover_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_operator_source_failover.transmit_identifications[operator_failover_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_operator_source_failover.transmit_descriptors[operator_failover_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_operator_source_failover.transmit_next_cursors[operator_failover_tx_index]);
    }
    debugWrite(", timestamps operator/refresh/recovery 0x");
    debugWriteHex64(network.ntp_operator_source_failover.operator_refresh_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_operator_source_failover.automatic_refresh_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_operator_source_failover.recovery_timestamp);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_operator_source_failover.timestamps_automatic) "yes" else "no");
    debugWrite(", manual accepted/rotation-preserved ");
    debugWrite(if (network.ntp_operator_source_failover.operator_refresh_accepted) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_failover.manual_rotation_preserved) "yes" else "no");
    debugWrite(", automatic refresh/retry timestamp ");
    debugWrite(if (network.ntp_operator_source_failover.automatic_refresh_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_failover.retry_timestamp_preserved) "yes" else "no");
    debugWrite(", timeout waiting/no-TX/pending/failures ");
    debugWrite(if (network.ntp_operator_source_failover.timeout_waiting) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_failover.timeout_no_tx) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.timeout_pending_source);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.timeout_failure_count);
    debugWrite(", cooldown no-TX ");
    debugWrite(if (network.ntp_operator_source_failover.cooldown_no_tx) "yes" else "no");
    debugWrite(", recovery start/switch/socket/rotations ");
    debugWrite(if (network.ntp_operator_source_failover.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_failover.recovery_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_failover.same_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.automatic_rotation_count);
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_operator_source_failover.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_operator_source_failover.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_operator_source_failover.accepted_fraction);
    debugWrite(" clean ");
    debugWrite(if (network.ntp_operator_source_failover.fallback_state_clean) "yes" else "no");
    debugWrite(" health source/recovery/cumulative ");
    debugWrite(if (network.ntp_operator_source_failover.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_failover.health_reports_recovery) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_source_failover.health_preserves_cumulative) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.step_rejected);
    debugWrite(" lifecycle/limits/success ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.recovery_successes);
    debugWrite(", close ");
    debugWrite(if (network.ntp_operator_source_failover.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_operator_source_failover.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_source_failover.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP stale source reply verified: source ");
    debugWriteReferenceKind(network.ntp_stale_source_reply.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.local_port);
    debugWrite(", pool/peer ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.previous_source_index);
    debugWrite("->");
    debugWriteU64Decimal(network.ntp_stale_source_reply.current_source_index);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_stale_source_reply.previous_server);
    debugWrite("->");
    debugWriteIpv4(network.ntp_stale_source_reply.current_server);
    debugWrite(", transmissions ");
    var stale_source_tx_index: usize = 0;
    while (stale_source_tx_index < network.ntp_stale_source_reply.transmit_identifications.len) : (stale_source_tx_index += 1) {
        if (stale_source_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_stale_source_reply.transmit_identifications[stale_source_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_stale_source_reply.transmit_descriptors[stale_source_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_stale_source_reply.transmit_next_cursors[stale_source_tx_index]);
    }
    debugWrite(", recovery timestamp 0x");
    debugWriteHex64(network.ntp_stale_source_reply.recovery_timestamp);
    debugWrite(" started/switched/socket ");
    debugWrite(if (network.ntp_stale_source_reply.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_stale_source_reply.recovery_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_stale_source_reply.same_socket_preserved) "yes" else "no");
    debugWrite(", old source rejected/peer-drop/no-sample/clock/request ");
    debugWrite(if (network.ntp_stale_source_reply.old_source_rejected) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.peer_drop_delta);
    debugWrite("/");
    debugWrite(if (network.ntp_stale_source_reply.old_source_no_sample) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_stale_source_reply.old_source_clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_stale_source_reply.old_source_request_preserved) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_stale_source_reply.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_stale_source_reply.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_stale_source_reply.accepted_fraction);
    debugWrite(" clean ");
    debugWrite(if (network.ntp_stale_source_reply.accepted_state_clean) "yes" else "no");
    debugWrite(" health source/recovery ");
    debugWrite(if (network.ntp_stale_source_reply.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_stale_source_reply.health_reports_recovery) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.step_rejected);
    debugWrite(" lifecycle/limits/success ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.recovery_successes);
    debugWrite(", close ");
    debugWrite(if (network.ntp_stale_source_reply.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_stale_source_reply.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_stale_source_reply.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP wrong originate reply verified: source ");
    debugWriteReferenceKind(network.ntp_wrong_originate_reply.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.local_port);
    debugWrite(", pool/source/server ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.source_index);
    debugWrite("/");
    debugWriteIpv4(network.ntp_wrong_originate_reply.server);
    debugWrite(", transmissions ");
    var wrong_originate_tx_index: usize = 0;
    while (wrong_originate_tx_index < network.ntp_wrong_originate_reply.transmit_identifications.len) : (wrong_originate_tx_index += 1) {
        if (wrong_originate_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_wrong_originate_reply.transmit_identifications[wrong_originate_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_wrong_originate_reply.transmit_descriptors[wrong_originate_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_wrong_originate_reply.transmit_next_cursors[wrong_originate_tx_index]);
    }
    debugWrite(", recovery timestamp 0x");
    debugWriteHex64(network.ntp_wrong_originate_reply.recovery_timestamp);
    debugWrite(" started/switched/socket ");
    debugWrite(if (network.ntp_wrong_originate_reply.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.recovery_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.same_socket_preserved) "yes" else "no");
    debugWrite(", wrong originate routed/examined/rejected/pending ");
    debugWrite(if (network.ntp_wrong_originate_reply.wrong_originate_routed) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.wrong_originate_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.wrong_originate_rejected);
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.wrong_originate_pending) "yes" else "no");
    debugWrite(" no-sample/quality/step/apply/clock/request/peer-drop ");
    debugWrite(if (network.ntp_wrong_originate_reply.wrong_originate_no_sample) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.wrong_originate_no_quality) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.wrong_originate_no_step) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.wrong_originate_no_apply) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.wrong_originate_clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.wrong_originate_request_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.peer_drop_preserved) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_wrong_originate_reply.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_wrong_originate_reply.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_wrong_originate_reply.accepted_fraction);
    debugWrite(" clean ");
    debugWrite(if (network.ntp_wrong_originate_reply.accepted_state_clean) "yes" else "no");
    debugWrite(" health source/recovery ");
    debugWrite(if (network.ntp_wrong_originate_reply.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_wrong_originate_reply.health_reports_recovery) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.step_rejected);
    debugWrite(" lifecycle/limits/success ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.recovery_successes);
    debugWrite(", close ");
    debugWrite(if (network.ntp_wrong_originate_reply.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_wrong_originate_reply.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP mixed response batch verified: source ");
    debugWriteReferenceKind(network.ntp_mixed_response_batch.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.local_port);
    debugWrite(", pool/source/server ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.source_index);
    debugWrite("/");
    debugWriteIpv4(network.ntp_mixed_response_batch.server);
    debugWrite(", transmissions ");
    var mixed_batch_tx_index: usize = 0;
    while (mixed_batch_tx_index < network.ntp_mixed_response_batch.transmit_identifications.len) : (mixed_batch_tx_index += 1) {
        if (mixed_batch_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_mixed_response_batch.transmit_identifications[mixed_batch_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_mixed_response_batch.transmit_descriptors[mixed_batch_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_mixed_response_batch.transmit_next_cursors[mixed_batch_tx_index]);
    }
    debugWrite(", recovery timestamp 0x");
    debugWriteHex64(network.ntp_mixed_response_batch.recovery_timestamp);
    debugWrite(" started/switched/socket ");
    debugWrite(if (network.ntp_mixed_response_batch.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_mixed_response_batch.recovery_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_mixed_response_batch.same_socket_preserved) "yes" else "no");
    debugWrite(", queued wrong/valid ");
    debugWrite(if (network.ntp_mixed_response_batch.wrong_routed) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_mixed_response_batch.valid_routed) "yes" else "no");
    debugWrite(" poll ");
    debugWriteNtpState(network.ntp_mixed_response_batch.batch_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.batch_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.batch_rejected);
    debugWrite(" resolved/sample/no-retry/peer-drop ");
    debugWrite(if (network.ntp_mixed_response_batch.batch_resolved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_mixed_response_batch.sampled_once) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_mixed_response_batch.no_retry) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_mixed_response_batch.peer_drop_preserved) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_mixed_response_batch.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_mixed_response_batch.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_mixed_response_batch.accepted_fraction);
    debugWrite(" clean ");
    debugWrite(if (network.ntp_mixed_response_batch.accepted_state_clean) "yes" else "no");
    debugWrite(" health source/recovery ");
    debugWrite(if (network.ntp_mixed_response_batch.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_mixed_response_batch.health_reports_recovery) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.step_rejected);
    debugWrite(" lifecycle/limits/success ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.recovery_successes);
    debugWrite(", close ");
    debugWrite(if (network.ntp_mixed_response_batch.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_mixed_response_batch.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP rejected deadline retry verified: source ");
    debugWriteReferenceKind(network.ntp_rejected_deadline_retry.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.local_port);
    debugWrite(", pool/source/server ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.source_index);
    debugWrite("/");
    debugWriteIpv4(network.ntp_rejected_deadline_retry.server);
    debugWrite(", transmissions ");
    var rejected_deadline_tx_index: usize = 0;
    while (rejected_deadline_tx_index < network.ntp_rejected_deadline_retry.transmit_identifications.len) : (rejected_deadline_tx_index += 1) {
        if (rejected_deadline_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_rejected_deadline_retry.transmit_identifications[rejected_deadline_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_rejected_deadline_retry.transmit_descriptors[rejected_deadline_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_rejected_deadline_retry.transmit_next_cursors[rejected_deadline_tx_index]);
    }
    debugWrite(", recovery timestamp 0x");
    debugWriteHex64(network.ntp_rejected_deadline_retry.recovery_timestamp);
    debugWrite(" started/switched/socket ");
    debugWrite(if (network.ntp_rejected_deadline_retry.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.recovery_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.same_socket_preserved) "yes" else "no");
    debugWrite(", wrong routed/poll ");
    debugWrite(if (network.ntp_rejected_deadline_retry.wrong_routed) "yes" else "no");
    debugWrite("/");
    debugWriteNtpState(network.ntp_rejected_deadline_retry.poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.poll_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.poll_rejected);
    debugWrite(" no-sample/quality/step/apply/clock/request/peer-drop ");
    debugWrite(if (network.ntp_rejected_deadline_retry.no_sample) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.no_quality) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.no_step) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.no_apply) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.request_preserved_before_retry) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.peer_drop_preserved) "yes" else "no");
    debugWrite(", deadline retry/timestamp/transmissions/rejection-counters ");
    debugWrite(if (network.ntp_rejected_deadline_retry.deadline_retry_sent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.retry_timestamp_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.retry_transmissions);
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.rejection_counters_unchanged) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_rejected_deadline_retry.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_rejected_deadline_retry.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_rejected_deadline_retry.accepted_fraction);
    debugWrite(" clean ");
    debugWrite(if (network.ntp_rejected_deadline_retry.accepted_state_clean) "yes" else "no");
    debugWrite(" health source/recovery ");
    debugWrite(if (network.ntp_rejected_deadline_retry.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_rejected_deadline_retry.health_reports_recovery) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.step_rejected);
    debugWrite(" lifecycle/limits/success ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.recovery_successes);
    debugWrite(", close ");
    debugWrite(if (network.ntp_rejected_deadline_retry.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_rejected_deadline_retry.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP budgeted retry queue verified: source ");
    debugWriteReferenceKind(network.ntp_budgeted_retry_queue.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.local_port);
    debugWrite(", pool/source/server ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.source_index);
    debugWrite("/");
    debugWriteIpv4(network.ntp_budgeted_retry_queue.server);
    debugWrite(", transmissions ");
    var budgeted_queue_tx_index: usize = 0;
    while (budgeted_queue_tx_index < network.ntp_budgeted_retry_queue.transmit_identifications.len) : (budgeted_queue_tx_index += 1) {
        if (budgeted_queue_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_budgeted_retry_queue.transmit_identifications[budgeted_queue_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_budgeted_retry_queue.transmit_descriptors[budgeted_queue_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_budgeted_retry_queue.transmit_next_cursors[budgeted_queue_tx_index]);
    }
    debugWrite(", recovery timestamp 0x");
    debugWriteHex64(network.ntp_budgeted_retry_queue.recovery_timestamp);
    debugWrite(" started/switched/socket ");
    debugWrite(if (network.ntp_budgeted_retry_queue.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.recovery_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.same_socket_preserved) "yes" else "no");
    debugWrite(", queued wrong/valid ");
    debugWrite(if (network.ntp_budgeted_retry_queue.wrong_routed) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.valid_routed) "yes" else "no");
    debugWrite(" first ");
    debugWriteNtpState(network.ntp_budgeted_retry_queue.first_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.first_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.first_rejected);
    debugWrite(" no-sample/discipline ");
    debugWrite(if (network.ntp_budgeted_retry_queue.first_no_sample) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.first_no_discipline) "yes" else "no");
    debugWrite(" retry/timestamp/transmissions ");
    debugWrite(if (network.ntp_budgeted_retry_queue.retry_sent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.retry_timestamp_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.retry_transmissions);
    debugWrite(" retained pending/readable/peer-drop ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.retained_pending_packets);
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.retained_readable) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.peer_drop_preserved) "yes" else "no");
    debugWrite(", second ");
    debugWriteNtpState(network.ntp_budgeted_retry_queue.second_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.second_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.second_rejected);
    debugWrite(" resolved/no-extra-retry ");
    debugWrite(if (network.ntp_budgeted_retry_queue.second_resolved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.no_extra_retry) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_budgeted_retry_queue.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_budgeted_retry_queue.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_budgeted_retry_queue.accepted_fraction);
    debugWrite(" clean/queue-empty ");
    debugWrite(if (network.ntp_budgeted_retry_queue.accepted_state_clean) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.final_queue_empty) "yes" else "no");
    debugWrite(" health source/recovery ");
    debugWrite(if (network.ntp_budgeted_retry_queue.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_budgeted_retry_queue.health_reports_recovery) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.step_rejected);
    debugWrite(" lifecycle/limits/success ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.recovery_successes);
    debugWrite(", close ");
    debugWrite(if (network.ntp_budgeted_retry_queue.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_budgeted_retry_queue.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP zero budget deadline verified: source ");
    debugWriteReferenceKind(network.ntp_zero_budget_deadline.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.local_port);
    debugWrite(", pool/source/server ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.source_index);
    debugWrite("/");
    debugWriteIpv4(network.ntp_zero_budget_deadline.server);
    debugWrite(", transmissions ");
    var zero_budget_tx_index: usize = 0;
    while (zero_budget_tx_index < network.ntp_zero_budget_deadline.transmit_identifications.len) : (zero_budget_tx_index += 1) {
        if (zero_budget_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_zero_budget_deadline.transmit_identifications[zero_budget_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_zero_budget_deadline.transmit_descriptors[zero_budget_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_zero_budget_deadline.transmit_next_cursors[zero_budget_tx_index]);
    }
    debugWrite(", recovery timestamp 0x");
    debugWriteHex64(network.ntp_zero_budget_deadline.recovery_timestamp);
    debugWrite(" started/switched/socket ");
    debugWrite(if (network.ntp_zero_budget_deadline.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.recovery_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.same_socket_preserved) "yes" else "no");
    debugWrite(", valid routed ");
    debugWrite(if (network.ntp_zero_budget_deadline.valid_routed) "yes" else "no");
    debugWrite(" zero ");
    debugWriteNtpState(network.ntp_zero_budget_deadline.zero_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.zero_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.zero_rejected);
    debugWrite(" response-absent/no-sample/discipline ");
    debugWrite(if (network.ntp_zero_budget_deadline.zero_response_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.zero_no_sample) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.zero_no_discipline) "yes" else "no");
    debugWrite(" retry/timestamp/transmissions ");
    debugWrite(if (network.ntp_zero_budget_deadline.retry_sent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.retry_timestamp_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.retry_transmissions);
    debugWrite(" retained pending/counters/readable/peer-drop ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.retained_pending_packets);
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.retained_queue_counters_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.retained_readable) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.peer_drop_preserved) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpState(network.ntp_zero_budget_deadline.accepted_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.accepted_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.accepted_rejected);
    debugWrite(" resolved/no-extra-retry ");
    debugWrite(if (network.ntp_zero_budget_deadline.accepted_resolved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.no_extra_retry) "yes" else "no");
    debugWrite(" result ");
    debugWriteNtpQuality(network.ntp_zero_budget_deadline.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_zero_budget_deadline.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_zero_budget_deadline.accepted_fraction);
    debugWrite(" clean/queue-empty ");
    debugWrite(if (network.ntp_zero_budget_deadline.accepted_state_clean) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.final_queue_empty) "yes" else "no");
    debugWrite(" health source/recovery ");
    debugWrite(if (network.ntp_zero_budget_deadline.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_zero_budget_deadline.health_reports_recovery) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.step_rejected);
    debugWrite(" lifecycle/limits/success ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.recovery_successes);
    debugWrite(", close ");
    debugWrite(if (network.ntp_zero_budget_deadline.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_zero_budget_deadline.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP post-response purge verified: source ");
    debugWriteReferenceKind(network.ntp_post_response_purge.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_post_response_purge.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_post_response_purge.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_post_response_purge.server);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_post_response_purge.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.initial_next_cursor);
    debugWrite(", queue before pending/enqueued/dequeued/high-water ");
    debugWriteU64Decimal(network.ntp_post_response_purge.queued_responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.queue_enqueued_before);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.queue_dequeued_before);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.queue_high_water);
    debugWrite(", accepted ");
    debugWriteNtpState(network.ntp_post_response_purge.accepted_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.accepted_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.accepted_rejected);
    debugWrite(" result ");
    debugWriteNtpQuality(network.ntp_post_response_purge.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_post_response_purge.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_post_response_purge.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_post_response_purge.accepted_fraction);
    debugWrite(", purged ");
    debugWriteU64Decimal(network.ntp_post_response_purge.post_response_discards);
    debugWrite(" queue after pending/enqueued/dequeued/dropped/empty ");
    debugWriteU64Decimal(network.ntp_post_response_purge.queue_pending_after);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.queue_enqueued_after);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.queue_dequeued_after);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.queue_dropped_after);
    debugWrite("/");
    debugWrite(if (network.ntp_post_response_purge.queue_empty) "yes" else "no");
    debugWrite(" health synchronized/discards ");
    debugWrite(if (network.ntp_post_response_purge.health_synchronized) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_post_response_purge.health_reports_discards) "yes" else "no");
    debugWrite(" idle no-TX/state ");
    debugWrite(if (network.ntp_post_response_purge.idle_no_tx) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_post_response_purge.idle_state_preserved) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_post_response_purge.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_post_response_purge.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.step_rejected);
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_post_response_purge.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.responses);
    debugWrite(", close ");
    debugWrite(if (network.ntp_post_response_purge.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_post_response_purge.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_post_response_purge.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_post_response_purge.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_post_response_purge.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_post_response_purge.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_post_response_purge.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_post_response_purge.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP quality rejection queue verified: source ");
    debugWriteReferenceKind(network.ntp_quality_rejection_queue.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_quality_rejection_queue.server);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.initial_next_cursor);
    debugWrite(", queued ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.queued_before);
    debugWrite(" first ");
    debugWriteNtpState(network.ntp_quality_rejection_queue.first_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.first_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.first_rejected);
    debugWrite(" result/action/count/remaining ");
    debugWriteNtpQuality(network.ntp_quality_rejection_queue.first_quality_result);
    debugWrite("/");
    debugWriteNtpQualityRejectionAction(network.ntp_quality_rejection_queue.first_rejection_action);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.first_rejection_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.first_remaining);
    debugWrite(" no-sample/apply/clock/request/purge ");
    debugWrite(if (network.ntp_quality_rejection_queue.first_no_sample) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_queue.first_no_apply) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_queue.first_clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_queue.first_request_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_queue.purge_not_run) "yes" else "no");
    debugWrite(" retained pending/readable/accounting ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.retained_pending);
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_queue.retained_readable) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_queue.retained_queue_accounting) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpState(network.ntp_quality_rejection_queue.accepted_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.accepted_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.accepted_rejected);
    debugWrite(" result ");
    debugWriteNtpQuality(network.ntp_quality_rejection_queue.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_quality_rejection_queue.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_quality_rejection_queue.accepted_fraction);
    debugWrite(" clean/queue-empty/health-no-discards ");
    debugWrite(if (network.ntp_quality_rejection_queue.accepted_state_clean) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_queue.final_queue_empty) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_queue.health_reports_no_discards) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.quality_rejected);
    debugWrite("/dispersion ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.quality_root_dispersion_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.step_rejected);
    debugWrite(" lifecycle/discards ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.post_response_discards);
    debugWrite(", close ");
    debugWrite(if (network.ntp_quality_rejection_queue.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_queue.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP step rejection queue verified: source ");
    debugWriteReferenceKind(network.ntp_step_rejection_queue.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_step_rejection_queue.server);
    debugWrite(", transmissions ");
    var step_queue_tx_index: usize = 0;
    while (step_queue_tx_index < network.ntp_step_rejection_queue.transmit_identifications.len) : (step_queue_tx_index += 1) {
        if (step_queue_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_step_rejection_queue.transmit_identifications[step_queue_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_step_rejection_queue.transmit_descriptors[step_queue_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_step_rejection_queue.transmit_next_cursors[step_queue_tx_index]);
    }
    debugWrite(", refresh timestamp 0x");
    debugWriteHex64(network.ntp_step_rejection_queue.refresh_timestamp);
    debugWrite(" queued ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.queued_before);
    debugWrite(" first ");
    debugWriteNtpState(network.ntp_step_rejection_queue.first_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.first_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.first_rejected);
    debugWrite(" result/action/count/remaining ");
    debugWriteNtpQuality(network.ntp_step_rejection_queue.first_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_step_rejection_queue.first_step_result);
    debugWrite("/");
    debugWriteNtpStepRejectionAction(network.ntp_step_rejection_queue.first_rejection_action);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.first_rejection_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.first_remaining);
    debugWrite(" sample ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.first_sample_tick);
    debugWrite(" apply-absent/clock/request/purge ");
    debugWrite(if (network.ntp_step_rejection_queue.first_apply_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_queue.first_clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_queue.first_request_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_queue.purge_not_run) "yes" else "no");
    debugWrite(" retained pending/readable/accounting ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.retained_pending);
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_queue.retained_readable) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_queue.retained_queue_accounting) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpState(network.ntp_step_rejection_queue.accepted_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.accepted_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.accepted_rejected);
    debugWrite(" result ");
    debugWriteNtpQuality(network.ntp_step_rejection_queue.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_step_rejection_queue.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_step_rejection_queue.accepted_fraction);
    debugWrite(" clean/queue-empty/health-no-discards ");
    debugWrite(if (network.ntp_step_rejection_queue.accepted_state_clean) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_queue.final_queue_empty) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_queue.health_reports_no_discards) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.step_rejected);
    debugWrite("/forward ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.step_excessive_forward_rejected);
    debugWrite(" lifecycle/discards ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.post_response_discards);
    debugWrite(", close ");
    debugWrite(if (network.ntp_step_rejection_queue.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_queue.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP transaction rejection queue verified: source ");
    debugWriteReferenceKind(network.ntp_transaction_rejection_queue.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_transaction_rejection_queue.server);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.initial_next_cursor);
    debugWrite(" queued ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.queued_before);
    debugWrite(" first ");
    debugWriteNtpState(network.ntp_transaction_rejection_queue.first_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.first_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.first_rejected);
    debugWrite(" response/sample/quality/step/apply absent ");
    debugWrite(if (network.ntp_transaction_rejection_queue.first_response_absent) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.first_no_sample) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.first_no_quality) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.first_no_step) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.first_no_apply) "yes" else "no");
    debugWrite(" clock/request/purge ");
    debugWrite(if (network.ntp_transaction_rejection_queue.first_clock_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.first_request_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.purge_not_run) "yes" else "no");
    debugWrite(" retained pending/readable/accounting ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.retained_pending);
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.retained_readable) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.retained_queue_accounting) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpState(network.ntp_transaction_rejection_queue.accepted_poll_state);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.accepted_examined);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.accepted_rejected);
    debugWrite(" result ");
    debugWriteNtpQuality(network.ntp_transaction_rejection_queue.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_transaction_rejection_queue.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_transaction_rejection_queue.accepted_fraction);
    debugWrite(" clean/queue-empty/health-no-discards ");
    debugWrite(if (network.ntp_transaction_rejection_queue.accepted_state_clean) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.final_queue_empty) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transaction_rejection_queue.health_reports_no_discards) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.step_rejected);
    debugWrite(" lifecycle/discards ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.post_response_discards);
    debugWrite(", close ");
    debugWrite(if (network.ntp_transaction_rejection_queue.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transaction_rejection_queue.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP pre-request purge verified: source ");
    debugWriteReferenceKind(network.ntp_pre_request_purge.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_pre_request_purge.server);
    debugWrite(", transmissions ");
    var pre_request_tx_index: usize = 0;
    while (pre_request_tx_index < network.ntp_pre_request_purge.transmit_identifications.len) : (pre_request_tx_index += 1) {
        if (pre_request_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_pre_request_purge.transmit_identifications[pre_request_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_pre_request_purge.transmit_descriptors[pre_request_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_pre_request_purge.transmit_next_cursors[pre_request_tx_index]);
    }
    debugWrite(", initial ");
    debugWriteNtpQuality(network.ntp_pre_request_purge.initial_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_pre_request_purge.initial_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.initial_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.initial_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_pre_request_purge.initial_fraction);
    debugWrite(" discards-zero ");
    debugWrite(if (network.ntp_pre_request_purge.initial_discards_zero) "yes" else "no");
    debugWrite(", idle stale pending/readable/accounting ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.stale_pending_before_refresh);
    debugWrite("/");
    debugWrite(if (network.ntp_pre_request_purge.stale_readable_before_refresh) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_pre_request_purge.stale_queue_accounting) "yes" else "no");
    debugWrite(", refresh timestamp 0x");
    debugWriteHex64(network.ntp_pre_request_purge.refresh_timestamp);
    debugWrite(" started/projected ");
    debugWrite(if (network.ntp_pre_request_purge.refresh_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_pre_request_purge.refresh_timestamp_projected) "yes" else "no");
    debugWrite(" purge pre/post/before-TX/queue-empty/request-active ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.pre_request_purge_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.post_response_purge_count);
    debugWrite("/");
    debugWrite(if (network.ntp_pre_request_purge.purge_before_transmit) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_pre_request_purge.stale_queue_empty_after_start) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_pre_request_purge.refresh_request_active) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_pre_request_purge.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_pre_request_purge.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_pre_request_purge.accepted_fraction);
    debugWrite(" clean/queue-empty ");
    debugWrite(if (network.ntp_pre_request_purge.accepted_state_clean) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_pre_request_purge.final_queue_empty) "yes" else "no");
    debugWrite(" health pre/post ");
    debugWrite(if (network.ntp_pre_request_purge.health_reports_pre_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_pre_request_purge.health_reports_no_post_discards) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.step_rejected);
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.responses);
    debugWrite(", close ");
    debugWrite(if (network.ntp_pre_request_purge.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_pre_request_purge.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_pre_request_purge.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP recovery pre-switch purge verified: source ");
    debugWriteReferenceKind(network.ntp_recovery_pre_switch_purge.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.local_port);
    debugWrite(" pool/source ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.source_count);
    debugWrite("/0->1 servers ");
    debugWriteIpv4(network.ntp_recovery_pre_switch_purge.first_server);
    debugWrite("->");
    debugWriteIpv4(network.ntp_recovery_pre_switch_purge.second_server);
    debugWrite(", transmissions ");
    var recovery_purge_tx_index: usize = 0;
    while (recovery_purge_tx_index < network.ntp_recovery_pre_switch_purge.transmit_identifications.len) : (recovery_purge_tx_index += 1) {
        if (recovery_purge_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.transmit_identifications[recovery_purge_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.transmit_descriptors[recovery_purge_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.transmit_next_cursors[recovery_purge_tx_index]);
    }
    debugWrite(", timestamps refresh/recovery 0x");
    debugWriteHex64(network.ntp_recovery_pre_switch_purge.refresh_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_recovery_pre_switch_purge.recovery_timestamp);
    debugWrite(" automatic ");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.timestamps_automatic) "yes" else "no");
    debugWrite(", timeout waiting/pending/failures/deadline ");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.timeout_waiting) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.timeout_pending_source);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.timeout_failure_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.recovery_deadline_delta);
    debugWrite(", stale pending/readable/accounting ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.stale_pending_before_cooldown);
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.stale_readable_before_cooldown) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.stale_queue_accounting) "yes" else "no");
    debugWrite(" cooldown retained/no-TX ");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.cooldown_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.cooldown_no_tx) "yes" else "no");
    debugWrite(", recovery ready/start/switch/socket/purge/queue/request ");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.recovery_ready) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.source_switched) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.same_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.pre_request_purge_count);
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.stale_queue_empty_after_recovery_start) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.recovery_request_active) "yes" else "no");
    debugWrite(" pre/post ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.pre_request_purge_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.post_response_purge_count);
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_recovery_pre_switch_purge.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_recovery_pre_switch_purge.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_recovery_pre_switch_purge.accepted_fraction);
    debugWrite(" clean ");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.accepted_state_clean) "yes" else "no");
    debugWrite(" health source/purge/recovery ");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.health_reports_purge) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.health_reports_recovery) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.step_rejected);
    debugWrite(" lifecycle/limits/success/rotations ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.recovery_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.recovery_successes);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.source_rotations);
    debugWrite(", close ");
    debugWrite(if (network.ntp_recovery_pre_switch_purge.close_succeeded) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.final_tx_cursor);
    debugWrite(", submissions ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.tx_submissions_delta);
    debugWrite(", completions TX/RX ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.rx_completion_enqueues);
    debugWrite(", endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.final_generation_cursor);
    debugWrite(", ingress ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.ingress_dequeued);
    debugWrite(", dispatch ");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_recovery_pre_switch_purge.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP operator pre-switch purge verified: socket ");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.local_port);
    debugWrite(", pool/source ");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.original_source_index);
    debugWrite("->");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.target_source_index);
    debugWrite(" servers ");
    debugWriteIpv4(network.ntp_operator_pre_switch_purge.original_server);
    debugWrite("->");
    debugWriteIpv4(network.ntp_operator_pre_switch_purge.target_server);
    debugWrite(", terminal ");
    debugWrite(if (network.ntp_operator_pre_switch_purge.terminal_seeded) "yes" else "no");
    debugWrite(" stale pending/readable/accounting ");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.stale_pending_before_reset);
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.stale_readable_before_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.stale_queue_accounting) "yes" else "no");
    debugWrite(", invalid rejected/state/queue ");
    debugWrite(if (network.ntp_operator_pre_switch_purge.invalid_source_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.invalid_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.invalid_queue_preserved) "yes" else "no");
    debugWrite(", reset/socket/source/queue ");
    debugWrite(if (network.ntp_operator_pre_switch_purge.reset_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.same_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.target_source_selected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.queue_empty_after_reset) "yes" else "no");
    debugWrite(" discards pre-before/after/post ");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.pre_discards_before);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.pre_discards_after);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.post_discards_preserved);
    debugWrite(" transient/cumulative/rotations/duplicate ");
    debugWrite(if (network.ntp_operator_pre_switch_purge.transient_state_cleared) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.cumulative_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.rotations_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.duplicate_reset_rejected) "yes" else "no");
    debugWrite(" health source/discards/cumulative ");
    debugWrite(if (network.ntp_operator_pre_switch_purge.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.health_reports_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.health_reports_cumulative) "yes" else "no");
    debugWrite(", no-TX/close ");
    debugWrite(if (network.ntp_operator_pre_switch_purge.no_transmit_traffic) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_operator_pre_switch_purge.close_succeeded) "yes" else "no");
    debugWrite(", final endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.final_generation_cursor);
    debugWrite(" IP/TX ");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.final_tx_cursor);
    debugWrite(" completions TX/RX ");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.rx_completion_enqueues);
    debugWrite(" ingress ");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.ingress_dequeued);
    debugWrite(" dispatch ");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_operator_pre_switch_purge.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP same-source recovery purge verified: source ");
    debugWriteReferenceKind(network.ntp_same_source_recovery_purge.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.local_port);
    debugWrite(" pool/threshold/server ");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.failures_before_rotation);
    debugWrite("/");
    debugWriteIpv4(network.ntp_same_source_recovery_purge.server);
    debugWrite(", transmissions ");
    var ss_index: usize = 0;
    while (ss_index < 4) : (ss_index += 1) {
        if (ss_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_same_source_recovery_purge.transmit_identifications[ss_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_same_source_recovery_purge.transmit_descriptors[ss_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_same_source_recovery_purge.transmit_next_cursors[ss_index]);
    }
    debugWrite(", timestamps automatic ");
    debugWrite(if (network.ntp_same_source_recovery_purge.timestamps_automatic) "yes" else "no");
    debugWrite(" timeout/stale/cooldown ");
    debugWrite(if (network.ntp_same_source_recovery_purge.timeout_waiting) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.stale_pending);
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.cooldown_retained) "yes" else "no");
    debugWrite(" recovery/source/peer/socket/no-rotation/failure ");
    debugWrite(if (network.ntp_same_source_recovery_purge.recovery_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.same_source_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.same_peer_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.same_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.no_rotation) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.failure_preserved_until_accept) "yes" else "no");
    debugWrite(" purge pre/post/queue/request ");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.pre_request_discards);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.post_response_discards);
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.queue_empty_after_start) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.recovery_request_active) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_same_source_recovery_purge.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_same_source_recovery_purge.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_same_source_recovery_purge.accepted_fraction);
    debugWrite(" clean/failure-reset/health ");
    debugWrite(if (network.ntp_same_source_recovery_purge.accepted_clean) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.failure_reset_after_accept) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_recovery_purge.health_clean) "yes" else "no");
    debugWrite(" lifecycle/limit/success/rotations ");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.responses);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.retry_limit_hits);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.recovery_successes);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.source_rotations);
    debugWrite(", close/final IP/TX ");
    debugWrite(if (network.ntp_same_source_recovery_purge.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.final_tx_cursor);
    debugWrite(" submissions/completions ");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.tx_submissions_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.rx_completion_enqueues);
    debugWrite(" endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.final_generation_cursor);
    debugWrite(" ingress/dispatch ");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.ingress_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_recovery_purge.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP initial pre-request purge verified: source ");
    debugWriteReferenceKind(network.ntp_initial_pre_request_purge.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_initial_pre_request_purge.server);
    debugWrite(", stale pending/readable/accounting ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.stale_pending_before_start);
    debugWrite("/");
    debugWrite(if (network.ntp_initial_pre_request_purge.stale_readable_before_start) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_initial_pre_request_purge.stale_queue_accounting) "yes" else "no");
    debugWrite(", bootstrap 0x");
    debugWriteHex64(network.ntp_initial_pre_request_purge.bootstrap_timestamp);
    debugWrite(" TX ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.initial_next_cursor);
    debugWrite(" started/preserved ");
    debugWrite(if (network.ntp_initial_pre_request_purge.initial_started) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_initial_pre_request_purge.bootstrap_preserved) "yes" else "no");
    debugWrite(" purge pre/post/before-TX/queue/request ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.pre_request_discards);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.post_response_discards);
    debugWrite("/");
    debugWrite(if (network.ntp_initial_pre_request_purge.purge_before_transmit) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_initial_pre_request_purge.queue_empty_after_start) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_initial_pre_request_purge.request_active) "yes" else "no");
    debugWrite(", accepted ");
    debugWriteNtpQuality(network.ntp_initial_pre_request_purge.accepted_quality_result);
    debugWrite("/");
    debugWriteNtpStep(network.ntp_initial_pre_request_purge.accepted_step_result);
    debugWrite(" sample/time ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_initial_pre_request_purge.accepted_fraction);
    debugWrite(" clean/queue/health-discards/health-sync ");
    debugWrite(if (network.ntp_initial_pre_request_purge.accepted_clean) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_initial_pre_request_purge.final_queue_empty) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_initial_pre_request_purge.health_reports_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_initial_pre_request_purge.health_reports_synchronized) "yes" else "no");
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.responses);
    debugWrite(" close/final IP/TX ");
    debugWrite(if (network.ntp_initial_pre_request_purge.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.final_tx_cursor);
    debugWrite(" submissions/completions ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.tx_submissions_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.rx_completion_enqueues);
    debugWrite(" endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.final_generation_cursor);
    debugWrite(" ingress/dispatch ");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.ingress_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_initial_pre_request_purge.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP same-source operator reset purge verified: socket ");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.local_port);
    debugWrite(" pool/source/server ");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.source_count);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.source_index);
    debugWrite("/");
    debugWriteIpv4(network.ntp_same_source_operator_reset_purge.server);
    debugWrite(", terminal/stale/readable/accounting ");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.terminal_seeded) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.stale_pending_before_reset);
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.stale_readable_before_reset) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.stale_queue_accounting) "yes" else "no");
    debugWrite(" reset/source/peer/socket/queue ");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.reset_succeeded) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.same_source_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.same_peer_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.same_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.queue_empty_after_reset) "yes" else "no");
    debugWrite(" discards pre-before/after/post ");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.pre_discards_before);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.pre_discards_after);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.post_discards_preserved);
    debugWrite(" transient/cumulative/rotations ");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.transient_state_cleared) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.cumulative_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.rotations_preserved) "yes" else "no");
    debugWrite(" duplicate rejected/preserved ");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.duplicate_reset_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.duplicate_state_preserved) "yes" else "no");
    debugWrite(" health source/discards/cumulative ");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.health_reports_source) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.health_reports_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.health_reports_cumulative) "yes" else "no");
    debugWrite(" no-TX/close ");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.no_transmit_traffic) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_same_source_operator_reset_purge.close_succeeded) "yes" else "no");
    debugWrite(" final endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.final_generation_cursor);
    debugWrite(" IP/TX ");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.final_tx_cursor);
    debugWrite(" completions TX/RX ");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.rx_completion_enqueues);
    debugWrite(" ingress/dispatch ");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.ingress_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_same_source_operator_reset_purge.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP dual purge lifecycle verified: source ");
    debugWriteReferenceKind(network.ntp_dual_purge_lifecycle.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_dual_purge_lifecycle.server);
    debugWrite(", transmissions ");
    var dual_purge_tx_index: usize = 0;
    while (dual_purge_tx_index < 2) : (dual_purge_tx_index += 1) {
        if (dual_purge_tx_index != 0) debugWrite(" -> ");
        debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.transmit_identifications[dual_purge_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.transmit_descriptors[dual_purge_tx_index]);
        debugWrite("/");
        debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.transmit_next_cursors[dual_purge_tx_index]);
    }
    debugWrite(", timestamps bootstrap/refresh 0x");
    debugWriteHex64(network.ntp_dual_purge_lifecycle.bootstrap_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_dual_purge_lifecycle.refresh_timestamp);
    debugWrite(" projected ");
    debugWrite(if (network.ntp_dual_purge_lifecycle.refresh_timestamp_projected) "yes" else "no");
    debugWrite(", phases initial stale/start/responses/accepted ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.initial_stale_pending);
    debugWrite("/");
    debugWrite(if (network.ntp_dual_purge_lifecycle.initial_start_queue_empty) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.initial_response_pending);
    debugWrite("/");
    debugWrite(if (network.ntp_dual_purge_lifecycle.initial_accepted_clean) "yes" else "no");
    debugWrite(" refresh stale/start/responses/accepted ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.idle_stale_pending);
    debugWrite("/");
    debugWrite(if (network.ntp_dual_purge_lifecycle.refresh_start_queue_empty) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.refresh_response_pending);
    debugWrite("/");
    debugWrite(if (network.ntp_dual_purge_lifecycle.refresh_accepted_clean) "yes" else "no");
    debugWrite(", discards initial pre/post ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.initial_pre_discards);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.initial_post_discards);
    debugWrite(" final pre/post ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.refresh_pre_discards);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.refresh_post_discards);
    debugWrite(" queue enqueued/dequeued/high/empty ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.final_queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.final_queue_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.final_queue_high_water);
    debugWrite("/");
    debugWrite(if (network.ntp_dual_purge_lifecycle.final_queue_empty) "yes" else "no");
    debugWrite(" health discards/sync ");
    debugWrite(if (network.ntp_dual_purge_lifecycle.health_reports_independent_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_dual_purge_lifecycle.health_reports_synchronized) "yes" else "no");
    debugWrite(", counts quality ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.quality_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.quality_rejected);
    debugWrite(" step ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.step_accepted);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.step_rejected);
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.responses);
    debugWrite(" close/final IP/TX ");
    debugWrite(if (network.ntp_dual_purge_lifecycle.close_succeeded) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.final_tx_cursor);
    debugWrite(" submissions/completions ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.tx_submissions_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.rx_completion_enqueues);
    debugWrite(" endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.final_generation_cursor);
    debugWrite(" ingress/dispatch ");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.ingress_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_dual_purge_lifecycle.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP service close discard verified: source ");
    debugWriteReferenceKind(network.ntp_service_close_discard.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_service_close_discard.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_service_close_discard.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_service_close_discard.server);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_service_close_discard.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.initial_next_cursor);
    debugWrite(" request timestamp 0x");
    debugWriteHex64(network.ntp_service_close_discard.request_timestamp);
    debugWrite(" transmissions ");
    debugWriteU64Decimal(network.ntp_service_close_discard.request_transmissions);
    debugWrite(" queued/readable/accounting ");
    debugWriteU64Decimal(network.ntp_service_close_discard.queued_before_close);
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.queue_readable_before_close) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.queue_accounting_before_close) "yes" else "no");
    debugWrite(", close active/cancelled ");
    debugWrite(if (network.ntp_service_close_discard.request_was_active) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.request_cancelled) "yes" else "no");
    debugWrite(" socket ");
    debugWriteU64Decimal(network.ntp_service_close_discard.close_local_port);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.close_generation);
    debugWrite(" connected/peer ");
    debugWrite(if (network.ntp_service_close_discard.close_was_connected) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.close_peer_port);
    debugWrite(" discarded ");
    debugWriteU64Decimal(network.ntp_service_close_discard.discarded_packets);
    debugWrite(" queue ");
    debugWriteU64Decimal(network.ntp_service_close_discard.close_queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.close_queue_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.close_queue_high_water);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.close_queue_dropped);
    debugWrite(" purges ");
    debugWriteU64Decimal(network.ntp_service_close_discard.pre_request_discards);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.post_response_discards);
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_service_close_discard.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.responses);
    debugWrite(" inactive service/client/request ");
    debugWrite(if (network.ntp_service_close_discard.service_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.client_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.request_inactive) "yes" else "no");
    debugWrite(" stale status/receive/poll/retry ");
    debugWrite(if (network.ntp_service_close_discard.stale_status_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.stale_receive_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.stale_poll_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.stale_retry_rejected) "yes" else "no");
    debugWrite(" duplicate structured/boolean/preserved ");
    debugWrite(if (network.ntp_service_close_discard.duplicate_structured_close_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.duplicate_boolean_close_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.duplicate_state_preserved) "yes" else "no");
    debugWrite(" health inactive/discards/lifecycle ");
    debugWrite(if (network.ntp_service_close_discard.health_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.health_preserves_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_service_close_discard.health_preserves_lifecycle) "yes" else "no");
    debugWrite(", final IP/TX ");
    debugWriteU64Decimal(network.ntp_service_close_discard.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.final_tx_cursor);
    debugWrite(" submissions/completions ");
    debugWriteU64Decimal(network.ntp_service_close_discard.tx_submissions_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.rx_completion_enqueues);
    debugWrite(" endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_service_close_discard.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.final_generation_cursor);
    debugWrite(" ingress/dispatch ");
    debugWriteU64Decimal(network.ntp_service_close_discard.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.ingress_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_service_close_discard.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP close discard counter verified: source ");
    debugWriteReferenceKind(network.ntp_close_discard_counter.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_close_discard_counter.server);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.initial_next_cursor);
    debugWrite(" accepted sample/time ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_close_discard_counter.accepted_fraction);
    debugWrite(" clean/post-before-close ");
    debugWrite(if (network.ntp_close_discard_counter.accepted_clean) "yes" else "no");
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.post_response_discards_before_close);
    debugWrite(" idle pending/readable/accounting ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.idle_pending_before_close);
    debugWrite("/");
    debugWrite(if (network.ntp_close_discard_counter.idle_queue_readable) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_discard_counter.idle_queue_accounting) "yes" else "no");
    debugWrite(" close active/cancelled/timestamp/transmissions ");
    debugWrite(if (network.ntp_close_discard_counter.close_request_was_active) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_discard_counter.close_request_cancelled) "yes" else "no");
    debugWrite("/0x");
    debugWriteHex64(network.ntp_close_discard_counter.close_request_timestamp);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.close_request_transmissions);
    debugWrite(" discarded ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.discarded_packets);
    debugWrite(" queue ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.close_queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.close_queue_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.close_queue_high_water);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.close_queue_dropped);
    debugWrite(" discards pre/post/close ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.pre_request_discards);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.post_response_discards);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.close_discards);
    debugWrite(" clock/projected/inactive ");
    debugWrite(if (network.ntp_close_discard_counter.clock_preserved_after_close) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_discard_counter.projected_time_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_discard_counter.service_inactive) "yes" else "no");
    debugWrite(" health inactive/discards/lifecycle ");
    debugWrite(if (network.ntp_close_discard_counter.health_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_discard_counter.health_reports_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_discard_counter.health_reports_lifecycle) "yes" else "no");
    debugWrite(" duplicate rejected/preserved ");
    debugWrite(if (network.ntp_close_discard_counter.duplicate_close_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_discard_counter.duplicate_state_preserved) "yes" else "no");
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.responses);
    debugWrite(" final IP/TX ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.final_tx_cursor);
    debugWrite(" submissions/completions ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.tx_submissions_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.rx_completion_enqueues);
    debugWrite(" endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.final_generation_cursor);
    debugWrite(" ingress/dispatch ");
    debugWriteU64Decimal(network.ntp_close_discard_counter.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.ingress_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_discard_counter.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP transport-loss abandon verified: source ");
    debugWriteReferenceKind(network.ntp_transport_loss_abandon.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_transport_loss_abandon.server);
    debugWrite(", live rejected/preserved ");
    debugWrite(if (network.ntp_transport_loss_abandon.live_socket_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.live_state_preserved) "yes" else "no");
    debugWrite(" initial ");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.initial_next_cursor);
    debugWrite(" timestamp 0x");
    debugWriteHex64(network.ntp_transport_loss_abandon.request_timestamp);
    debugWrite(" queued ");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.queued_before_transport_loss);
    debugWrite(" external close discarded/queue ");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.transport_discarded_packets);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.transport_queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.transport_queue_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.transport_queue_high_water);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.transport_queue_dropped);
    debugWrite(" endpoint gone ");
    debugWrite(if (network.ntp_transport_loss_abandon.endpoint_invalidated) "yes" else "no");
    debugWrite(" abandon active/cancelled/timestamp/transmissions ");
    debugWrite(if (network.ntp_transport_loss_abandon.abandon_request_was_active) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.abandon_request_cancelled) "yes" else "no");
    debugWrite("/0x");
    debugWriteHex64(network.ntp_transport_loss_abandon.abandon_request_timestamp);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.abandon_request_transmissions);
    debugWrite(" socket/discards/lifecycle preserved ");
    debugWrite(if (network.ntp_transport_loss_abandon.abandon_socket_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.abandon_discards_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.abandon_lifecycle_preserved) "yes" else "no");
    debugWrite(" inactive service/client/request/cancelled ");
    debugWrite(if (network.ntp_transport_loss_abandon.service_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.client_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.request_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.request_cancelled) "yes" else "no");
    debugWrite(" clock ");
    debugWrite(if (network.ntp_transport_loss_abandon.clock_preserved) "yes" else "no");
    debugWrite(" duplicate/preserved/close-rejected ");
    debugWrite(if (network.ntp_transport_loss_abandon.duplicate_abandon_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.duplicate_state_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.close_rejected_after_abandon) "yes" else "no");
    debugWrite(" stale status/poll/retry ");
    debugWrite(if (network.ntp_transport_loss_abandon.stale_status_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.stale_poll_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.stale_retry_rejected) "yes" else "no");
    debugWrite(" health inactive/discards/lifecycle ");
    debugWrite(if (network.ntp_transport_loss_abandon.health_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.health_reports_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_transport_loss_abandon.health_reports_lifecycle) "yes" else "no");
    debugWrite(" final IP/TX ");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.final_tx_cursor);
    debugWrite(" submissions/completions ");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.tx_submissions_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.rx_completion_enqueues);
    debugWrite(" endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.final_generation_cursor);
    debugWrite(" ingress/dispatch ");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.ingress_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_transport_loss_abandon.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP close preflight verified: source ");
    debugWriteReferenceKind(network.ntp_close_preflight.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_close_preflight.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_close_preflight.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_close_preflight.server);
    debugWrite(", initial ");
    debugWriteU64Decimal(network.ntp_close_preflight.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.initial_next_cursor);
    debugWrite(" timestamp 0x");
    debugWriteHex64(network.ntp_close_preflight.request_timestamp);
    debugWrite(" queued/readable/accounting ");
    debugWriteU64Decimal(network.ntp_close_preflight.queued_before_transport_loss);
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.queue_readable_before_transport_loss) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.queue_accounting_before_transport_loss) "yes" else "no");
    debugWrite(" external close discarded/queue ");
    debugWriteU64Decimal(network.ntp_close_preflight.transport_discarded_packets);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.transport_queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.transport_queue_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.transport_queue_high_water);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.transport_queue_dropped);
    debugWrite(" endpoint gone ");
    debugWrite(if (network.ntp_close_preflight.endpoint_invalidated) "yes" else "no");
    debugWrite(" service/client/request active ");
    debugWrite(if (network.ntp_close_preflight.service_active_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.client_active_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.request_active_preserved) "yes" else "no");
    debugWrite(" request uncancelled ");
    debugWrite(if (network.ntp_close_preflight.request_uncancelled) "yes" else "no");
    debugWrite(" structured/boolean rejected ");
    debugWrite(if (network.ntp_close_preflight.structured_close_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.boolean_close_rejected) "yes" else "no");
    debugWrite(" state preserved ");
    debugWrite(if (network.ntp_close_preflight.state_preserved) "yes" else "no");
    debugWrite(" stale status/poll/retry ");
    debugWrite(if (network.ntp_close_preflight.stale_status_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.stale_poll_inactive) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.stale_retry_rejected) "yes" else "no");
    debugWrite(" health unsync/awaiting/discards/lifecycle ");
    debugWrite(if (network.ntp_close_preflight.health_unsynchronized) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.health_awaiting) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.health_reports_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_close_preflight.health_reports_lifecycle) "yes" else "no");
    debugWrite(" final IP/TX ");
    debugWriteU64Decimal(network.ntp_close_preflight.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.final_tx_cursor);
    debugWrite(" submissions/completions ");
    debugWriteU64Decimal(network.ntp_close_preflight.tx_submissions_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.rx_completion_enqueues);
    debugWrite(" endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_close_preflight.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.final_generation_cursor);
    debugWrite(" ingress/dispatch ");
    debugWriteU64Decimal(network.ntp_close_preflight.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.ingress_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_close_preflight.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP live discard saturation verified: source ");
    debugWriteReferenceKind(network.ntp_live_discard_saturation.source_kind);
    debugWrite(", frequency/bits ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.frequency_hz);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.counter_bits);
    debugWrite(", socket ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.socket_slot);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.socket_generation);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.local_port);
    debugWrite(" server ");
    debugWriteIpv4(network.ntp_live_discard_saturation.server);
    debugWrite(", start/max ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.saturation_start);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.saturation_result);
    debugWrite(" queues pre/response/close ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.stale_before_start);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.response_batch_pending);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.idle_before_close);
    debugWrite(" saturated ");
    debugWrite(if (network.ntp_live_discard_saturation.pre_request_saturated) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_discard_saturation.post_response_saturated) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_discard_saturation.close_discard_saturated) "yes" else "no");
    debugWrite(" initial ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.initial_identification);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.initial_descriptor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.initial_next_cursor);
    debugWrite(" timestamp 0x");
    debugWriteHex64(network.ntp_live_discard_saturation.request_timestamp);
    debugWrite(" accepted sample/time ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.accepted_sample_tick);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.accepted_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_live_discard_saturation.accepted_fraction);
    debugWrite(" clean ");
    debugWrite(if (network.ntp_live_discard_saturation.accepted_clean) "yes" else "no");
    debugWrite(" close discarded/queue ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.close_discarded_packets);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.close_queue_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.close_queue_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.close_queue_high_water);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.close_queue_dropped);
    debugWrite(" clock/projected/inactive ");
    debugWrite(if (network.ntp_live_discard_saturation.clock_preserved_after_close) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_discard_saturation.projected_time_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_discard_saturation.service_inactive) "yes" else "no");
    debugWrite(" health discards/lifecycle ");
    debugWrite(if (network.ntp_live_discard_saturation.health_reports_saturated_discards) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_discard_saturation.health_reports_lifecycle) "yes" else "no");
    debugWrite(" duplicate rejected/preserved ");
    debugWrite(if (network.ntp_live_discard_saturation.duplicate_close_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_live_discard_saturation.duplicate_state_preserved) "yes" else "no");
    debugWrite(" lifecycle ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.requests_started);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.retries);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.responses);
    debugWrite(" final IP/TX ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.final_identification_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.final_tx_cursor);
    debugWrite(" submissions/completions ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.tx_submissions_delta);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.tx_completion_enqueues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.tx_completion_dequeues);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.rx_completion_enqueues);
    debugWrite(" endpoints/cursor/generation ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.final_registered_endpoints);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.final_ephemeral_cursor);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.final_generation_cursor);
    debugWrite(" ingress/dispatch ");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.ingress_enqueued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.ingress_dequeued);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.packets_dispatched);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_live_discard_saturation.udp_dispatched);
    debugWrite("\r\n");
    debugWrite("NTP discard saturation verified: zero ");
    debugWrite(if (network.ntp_discard_saturation.zero_preserved) "yes" else "no");
    debugWrite(", normal ");
    debugWriteU64Decimal(network.ntp_discard_saturation.normal_start);
    debugWrite("+");
    debugWriteU64Decimal(network.ntp_discard_saturation.normal_added);
    debugWrite("=");
    debugWriteU64Decimal(network.ntp_discard_saturation.normal_result);
    debugWrite(", near-maximum ");
    debugWriteU64Decimal(network.ntp_discard_saturation.near_maximum_start);
    debugWrite("+");
    debugWriteU64Decimal(network.ntp_discard_saturation.near_maximum_added);
    debugWrite("=");
    debugWriteU64Decimal(network.ntp_discard_saturation.near_maximum_result);
    debugWrite(", maximum ");
    debugWrite(if (network.ntp_discard_saturation.maximum_preserved) "yes" else "no");
    debugWrite(", independent ");
    debugWriteU64Decimal(network.ntp_discard_saturation.independent_results[0]);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discard_saturation.independent_results[1]);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_discard_saturation.independent_results[2]);
    debugWrite("\r\n");
    debugWrite("NTP timestamp verified: base/anchor 0x");
    debugWriteHex64(network.ntp_timestamp.base_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_timestamp.anchor_timestamp);
    debugWrite(", quarter/rollover 0x");
    debugWriteHex64(network.ntp_timestamp.quarter_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_timestamp.rollover_timestamp);
    debugWrite(", maximum 0x");
    debugWriteHex64(network.ntp_timestamp.maximum_timestamp);
    debugWrite(", rejects unsynchronized/backward/overflow ");
    debugWrite(if (network.ntp_timestamp.unsynchronized_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_timestamp.backward_tick_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_timestamp.overflow_rejected) "yes" else "no");
    debugWrite("\r\n");
    debugWrite("NTP automatic timestamp verified: zero bootstrap rejected ");
    debugWrite(if (network.ntp_automatic_timestamp.zero_bootstrap_rejected) "yes" else "no");
    debugWrite(", bootstrap/anchor/quarter 0x");
    debugWriteHex64(network.ntp_automatic_timestamp.bootstrap_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_automatic_timestamp.anchor_timestamp);
    debugWrite("/0x");
    debugWriteHex64(network.ntp_automatic_timestamp.quarter_timestamp);
    debugWrite(", backward tick rejected ");
    debugWrite(if (network.ntp_automatic_timestamp.backward_tick_rejected) "yes" else "no");
    debugWrite("\r\n");
    debugWrite("NTP quality verified: fixture/boundary accepted ");
    debugWrite(if (network.ntp_quality.fixture_accepted) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality.boundary_accepted) "yes" else "no");
    debugWrite(", rejects invalid/stratum/positive-delay/negative-delay/dispersion ");
    debugWrite(if (network.ntp_quality.invalid_policy_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality.stratum_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality.positive_delay_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality.negative_delay_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality.dispersion_rejected) "yes" else "no");
    debugWrite(", delay magnitudes 0x");
    debugWriteHex32(network.ntp_quality.fixture_delay_magnitude);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_quality.negative_delay_magnitude);
    debugWrite("\r\n");
    debugWrite("NTP health verified: invalid thresholds zero/equal/reversed ");
    debugWrite(if (network.ntp_health.invalid_zero_holdover_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_health.invalid_equal_threshold_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_health.invalid_reversed_threshold_rejected) "yes" else "no");
    debugWrite(", states ");
    debugWriteNtpHealth(network.ntp_health.inactive_state);
    debugWrite("/");
    debugWriteNtpHealth(network.ntp_health.unsynchronized_state);
    debugWrite("/");
    debugWriteNtpHealth(network.ntp_health.synchronized_state);
    debugWrite("/");
    debugWriteNtpHealth(network.ntp_health.holdover_state);
    debugWrite("/");
    debugWriteNtpHealth(network.ntp_health.expired_state);
    debugWrite(", backward rejected ");
    debugWrite(if (network.ntp_health.backward_tick_rejected) "yes" else "no");
    debugWrite(", synchronized age/time ");
    debugWriteU64Decimal(network.ntp_health.synchronized_age_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_health.synchronized_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_health.synchronized_fraction);
    debugWrite(", holdover age/time ");
    debugWriteU64Decimal(network.ntp_health.holdover_age_ticks);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_health.holdover_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_health.holdover_fraction);
    debugWrite(", expired age/time absent ");
    debugWriteU64Decimal(network.ntp_health.expired_age_ticks);
    debugWrite("/");
    debugWrite(if (network.ntp_health.expired_time_absent) "yes" else "no");
    debugWrite(", awaiting/counters preserved ");
    debugWrite(if (network.ntp_health.awaiting_response_preserved) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_health.counters_preserved) "yes" else "no");
    debugWrite("\r\n");
    debugWrite("NTP retry policy verified: invalid zero-initial/cap/zero-retries ");
    debugWrite(if (network.ntp_retry_policy.invalid_zero_initial_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_retry_policy.invalid_cap_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_retry_policy.invalid_zero_retries_rejected) "yes" else "no");
    debugWrite(", intervals ");
    debugWriteU64Decimal(network.ntp_retry_policy.intervals[0]);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry_policy.intervals[1]);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry_policy.intervals[2]);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry_policy.intervals[3]);
    debugWrite(", limit rejected ");
    debugWrite(if (network.ntp_retry_policy.limit_rejected) "yes" else "no");
    debugWrite(", fixed ");
    debugWriteU64Decimal(network.ntp_retry_policy.fixed_intervals[0]);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry_policy.fixed_intervals[1]);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_retry_policy.fixed_intervals[2]);
    debugWrite(", overflow saturated ");
    debugWrite(if (network.ntp_retry_policy.overflow_saturated) "yes" else "no");
    debugWrite(" at ");
    debugWriteU64Decimal(network.ntp_retry_policy.maximum_value);
    debugWrite("\r\n");
    debugWrite("NTP recovery policy verified: invalid zero-cooldown/zero-recoveries ");
    debugWrite(if (network.ntp_recovery_policy.invalid_zero_cooldown_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_policy.invalid_zero_recoveries_rejected) "yes" else "no");
    debugWrite(", deadline ");
    debugWriteU64Decimal(network.ntp_recovery_policy.deadline_tick);
    debugWrite(", before/at/second/exhausted ");
    debugWrite(if (network.ntp_recovery_policy.waiting_before_deadline) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_policy.ready_at_deadline) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_policy.second_recovery_ready) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_policy.exhausted_at_limit) "yes" else "no");
    debugWrite(", overflow deadline ");
    debugWriteU64Decimal(network.ntp_recovery_policy.overflow_deadline_tick);
    debugWrite(" waiting/ready ");
    debugWrite(if (network.ntp_recovery_policy.overflow_waiting) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_recovery_policy.overflow_ready) "yes" else "no");
    debugWrite("\r\n");
    debugWrite("NTP step policy verified: invalid zero rejected ");
    debugWrite(if (network.ntp_step_policy.invalid_zero_rejected) "yes" else "no");
    debugWrite(", initial accepted ");
    debugWrite(if (network.ntp_step_policy.unsynchronized_initial_accepted) "yes" else "no");
    debugWrite(", stale equal/behind ");
    debugWrite(if (network.ntp_step_policy.stale_equal_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_policy.stale_behind_rejected) "yes" else "no");
    debugWrite(", exact borrow/no-borrow ");
    debugWrite(if (network.ntp_step_policy.exact_borrow_accepted) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_policy.exact_no_borrow_accepted) "yes" else "no");
    debugWrite(", excessive fraction/seconds ");
    debugWrite(if (network.ntp_step_policy.excessive_fraction_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_policy.excessive_seconds_rejected) "yes" else "no");
    debugWrite(", deltas borrow ");
    debugWriteU64Decimal(network.ntp_step_policy.borrow_delta_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_step_policy.borrow_delta_fraction);
    debugWrite(" no-borrow ");
    debugWriteU64Decimal(network.ntp_step_policy.no_borrow_delta_seconds);
    debugWrite("/0x");
    debugWriteHex32(network.ntp_step_policy.no_borrow_delta_fraction);
    debugWrite("\r\n");
    debugWrite("NTP source pool verified: invalid count zero/single/too-many ");
    debugWrite(if (network.ntp_source_pool.invalid_zero_count_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_pool.invalid_single_count_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_pool.invalid_too_many_rejected) "yes" else "no");
    debugWrite(", invalid zero/duplicate ");
    debugWrite(if (network.ntp_source_pool.invalid_zero_address_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_pool.invalid_duplicate_rejected) "yes" else "no");
    debugWrite(", valid two/max ");
    debugWrite(if (network.ntp_source_pool.valid_two_sources) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_pool.valid_maximum_sources) "yes" else "no");
    debugWrite(", sources ");
    debugWriteIpv4(network.ntp_source_pool.first_source);
    debugWrite("/");
    debugWriteIpv4(network.ntp_source_pool.second_source);
    debugWrite("/");
    debugWriteIpv4(network.ntp_source_pool.maximum_last_source);
    debugWrite(", lookup range/invalid/unused ");
    debugWrite(if (network.ntp_source_pool.out_of_range_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_pool.invalid_pool_lookup_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_pool.unused_slots_ignored) "yes" else "no");
    debugWrite("\r\n");
    debugWrite("NTP source rotation policy verified: invalid sources/single/threshold/index ");
    debugWrite(if (network.ntp_source_rotation_policy.invalid_zero_sources_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_rotation_policy.invalid_single_source_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_rotation_policy.invalid_zero_threshold_rejected) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_rotation_policy.invalid_source_index_rejected) "yes" else "no");
    debugWrite(", stay zero/first ");
    debugWrite(if (network.ntp_source_rotation_policy.zero_failures_stay) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_rotation_policy.first_failure_stay) "yes" else "no");
    debugWrite(" remaining ");
    debugWriteU64Decimal(network.ntp_source_rotation_policy.zero_remaining);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_rotation_policy.first_remaining);
    debugWrite(", rotate boundary/beyond ");
    debugWrite(if (network.ntp_source_rotation_policy.boundary_rotates) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_rotation_policy.beyond_rotates) "yes" else "no");
    debugWrite(" next ");
    debugWriteU64Decimal(network.ntp_source_rotation_policy.boundary_next_source);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_source_rotation_policy.beyond_next_source);
    debugWrite(", wrap 2->");
    debugWriteU64Decimal(network.ntp_source_rotation_policy.wrap_next_source);
    debugWrite(" ");
    debugWrite(if (network.ntp_source_rotation_policy.wrap_rotates) "yes" else "no");
    debugWrite(", maximum stay/rotate ");
    debugWrite(if (network.ntp_source_rotation_policy.maximum_penultimate_stays) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_source_rotation_policy.maximum_boundary_rotates) "yes" else "no");
    debugWrite(" next ");
    debugWriteU64Decimal(network.ntp_source_rotation_policy.maximum_boundary_next_source);
    debugWrite("\r\n");
    debugWrite("NTP quality rejection policy verified: invalid zero ");
    debugWrite(if (network.ntp_quality_rejection_policy.invalid_zero_rejected) "yes" else "no");
    debugWrite(", zero/first/penultimate retain ");
    debugWrite(if (network.ntp_quality_rejection_policy.zero_count_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_policy.first_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_policy.penultimate_retained) "yes" else "no");
    debugWrite(" remaining ");
    debugWriteU64Decimal(network.ntp_quality_rejection_policy.zero_count_remaining);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_policy.first_remaining);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_quality_rejection_policy.penultimate_remaining);
    debugWrite(", boundary/beyond retry ");
    debugWrite(if (network.ntp_quality_rejection_policy.boundary_retries) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_policy.beyond_retries) "yes" else "no");
    debugWrite(" remaining ");
    debugWriteU64Decimal(network.ntp_quality_rejection_policy.boundary_remaining);
    debugWrite(", maximum penultimate/boundary ");
    debugWrite(if (network.ntp_quality_rejection_policy.maximum_penultimate_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_quality_rejection_policy.maximum_boundary_retries) "yes" else "no");
    debugWrite("\r\n");
    debugWrite("NTP step rejection policy verified: invalid zero ");
    debugWrite(if (network.ntp_step_rejection_policy.invalid_zero_rejected) "yes" else "no");
    debugWrite(", zero/first/penultimate retain ");
    debugWrite(if (network.ntp_step_rejection_policy.zero_count_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_policy.first_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_policy.penultimate_retained) "yes" else "no");
    debugWrite(" remaining ");
    debugWriteU64Decimal(network.ntp_step_rejection_policy.zero_count_remaining);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_policy.first_remaining);
    debugWrite("/");
    debugWriteU64Decimal(network.ntp_step_rejection_policy.penultimate_remaining);
    debugWrite(", boundary/beyond retry ");
    debugWrite(if (network.ntp_step_rejection_policy.boundary_retries) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_policy.beyond_retries) "yes" else "no");
    debugWrite(" remaining ");
    debugWriteU64Decimal(network.ntp_step_rejection_policy.boundary_remaining);
    debugWrite(", maximum penultimate/boundary ");
    debugWrite(if (network.ntp_step_rejection_policy.maximum_penultimate_retained) "yes" else "no");
    debugWrite("/");
    debugWrite(if (network.ntp_step_rejection_policy.maximum_boundary_retries) "yes" else "no");
    debugWrite("\r\n");
    return true;
}

fn debugWriteNtpServiceState(state: e1000e.NtpServiceState) void {
    debugWrite(switch (state) {
        .inactive => "inactive",
        .idle => "idle",
        .awaiting => "awaiting",
        .timed_out => "timed-out",
    });
}
fn debugWriteNtpHealth(state: e1000e.NtpSynchronizationHealth) void {
    debugWrite(switch (state) {
        .inactive => "inactive",
        .unsynchronized => "unsynchronized",
        .synchronized => "synchronized",
        .holdover => "holdover",
        .expired => "expired",
    });
}
fn debugWriteReferenceKind(kind: time_reference.Kind) void {
    debugWrite(switch (kind) {
        .hpet => "HPET",
        .acpi_pm_timer => "ACPI PM timer",
        .pit_channel2 => "PIT channel 2",
    });
}

fn debugWriteNtpQualityRejectionAction(action: ntp.QualityRejectionAction) void {
    debugWrite(switch (action) {
        .invalid_policy => "invalid-policy",
        .retain_request => "retain",
        .retry_now => "retry-now",
    });
}

fn debugWriteNtpStepRejectionAction(action: ntp.StepRejectionAction) void {
    debugWrite(switch (action) {
        .invalid_policy => "invalid-policy",
        .retain_request => "retain",
        .retry_now => "retry-now",
    });
}

fn debugWriteNtpStep(result: ntp.ClockStepResult) void {
    debugWrite(switch (result) {
        .accepted => "accepted",
        .invalid_policy => "invalid-policy",
        .stale => "stale",
        .excessive_forward_step => "excessive-forward",
    });
}
fn debugWriteNtpQuality(result: ntp.QualityResult) void {
    debugWrite(switch (result) {
        .accepted => "accepted",
        .invalid_policy => "invalid-policy",
        .stratum => "stratum",
        .root_delay => "root-delay",
        .root_dispersion => "root-dispersion",
    });
}
fn debugWriteNtpApply(result: ntp.ClockApplyResult) void {
    debugWrite(switch (result) {
        .accepted => "accepted",
        .stale => "stale",
    });
}

fn debugWriteNtpState(state: e1000e.NtpRequestState) void {
    debugWrite(switch (state) {
        .inactive => "inactive",
        .pending => "pending",
        .resolved => "resolved",
    });
}

fn debugWriteDnsState(state: e1000e.DnsAQueryState) void {
    debugWrite(switch (state) {
        .inactive => "inactive",
        .pending => "pending",
        .resolved => "resolved",
        .not_found => "not-found",
    });
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

fn debugWriteHex32(value: u32) void {
    debugWriteHex16(@truncate(value >> 16));
    debugWriteHex16(@truncate(value));
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
fn debugWriteI64Decimal(value: i64) void {
    if (value >= 0) {
        debugWriteU64Decimal(@intCast(value));
        return;
    }
    debugWrite("-");
    const magnitude: u64 = @intCast(-(value + 1));
    debugWriteU64Decimal(magnitude + 1);
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
