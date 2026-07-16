const std = @import("std");
const boot = @import("boot_info.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const descriptor_tables = @import("descriptor_tables.zig");
const exceptions = @import("exceptions.zig");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const ioapic = @import("ioapic.zig");
const pci = @import("pci.zig");
const ahci = @import("ahci.zig");
const partition = @import("partition.zig");
const fat = @import("fat.zig");
const heap = @import("heap.zig");
const serial = @import("serial.zig");
const hpet = @import("hpet.zig");

const cc = std.os.uefi.cc;

var kernel_heap: heap.Heap = undefined;
var kernel_heap_ready: bool = false;

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
    const local_apic_info = initializeApic(acpi_info);
    initializeIoApic(acpi_info, local_apic_info);
    testApicTimer(acpi_info);
    const pci_inventory = enumeratePci(acpi_info);
    inspectAhci(pci_inventory, &frame_allocator);
    initializeKernelHeap(&frame_allocator);
    initializeSerial();

    if (info.framebuffer) |framebuffer| {
        paintFramebuffer(framebuffer);
        debugWrite("Framebuffer retained and written directly at 0x");
        debugWriteHex64(@intCast(framebuffer.base));
        debugWrite("\r\n");
    } else {
        debugWrite("No writable framebuffer was retained.\r\n");
    }

    debugWrite("ZigOs boot sequence complete: kernel foundations and hardware probes passed.\r\n");
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

fn initializeIoApic(discovery: acpi.Discovery, local_apic: apic.Information) void {
    const madt = discovery.madt orelse ioApicFailure("validated ACPI did not contain a MADT");
    const information = ioapic.initialize(madt, local_apic.apic_id) orelse
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
}

fn ioApicFailure(reason: []const u8) noreturn {
    debugWrite("IOAPIC initialization failure: ");
    debugWrite(reason);
    debugWrite("\r\n");
    zigos_halt_forever();
}

fn enumeratePci(discovery: acpi.Discovery) pci.Inventory {
    const mcfg_address = discovery.mcfg_address orelse pciFailure("ACPI did not expose an MCFG table");
    const inventory = pci.enumerate(mcfg_address) orelse
        pciFailure("MCFG validation or ECAM enumeration failed");

    debugWrite("PCIe ECAM active: MCFG 0x");
    debugWriteHex64(@intCast(inventory.mcfg_address));
    debugWrite(", allocations ");
    debugWriteUsizeDecimal(inventory.allocation_count);
    debugWrite(", buses scanned ");
    debugWriteUsizeDecimal(inventory.scanned_bus_count);
    debugWrite("\r\n");
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
    debugWrite("PCIe discovery failure: ");
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

fn inspectAhci(inventory: pci.Inventory, allocator: *memory.FrameAllocator) void {
    var controller_function: ?pci.Function = null;
    for (inventory.functions[0..inventory.retained_count]) |function| {
        if (function.class_code == 0x01 and function.subclass == 0x06 and function.programming_interface == 0x01) {
            controller_function = function;
            break;
        }
    }

    const function = controller_function orelse ahciFailure("no AHCI-class PCI function was enumerated");
    const controller = ahci.inspect(function) orelse
        ahciFailure("AHCI BAR5 or host-register validation failed");

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
    const identity = ahci.identifyFirstSata(controller, allocator) orelse
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
    const sector_zero = ahci.readOneSector(controller, identity, 0) orelse
        ahciFailure("READ DMA EXT for LBA 0 did not complete successfully");
    debugWrite("READ DMA EXT completed: LBA ");
    debugWriteU64Decimal(sector_zero.lba);
    debugWrite(", ");
    debugWriteU64Decimal(sector_zero.byte_count);
    debugWrite(" bytes at 0x");
    debugWriteHex64(@intCast(sector_zero.buffer_address));
    debugWrite("\r\n");
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
    for (text) |character| {
        zigos_debug_putc(character);
        _ = serial.putByte(character);
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
