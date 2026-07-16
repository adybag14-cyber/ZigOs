pub const FramebufferInfo = struct {
    base: usize,
    size: usize,
    width: u32,
    height: u32,
    pixels_per_scan_line: u32,
    pixel_format: u32,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    reserved_mask: u32,
};

pub const MemoryMapInfo = struct {
    address: usize,
    descriptor_count: usize,
    descriptor_size: usize,
    descriptor_version: u32,
    total_pages: u64,
    conventional_pages: u64,
    highest_physical_address: u64,
};

pub const KernelStackInfo = struct {
    base: usize,
    size: usize,
};

pub const BootInfo = struct {
    memory_map: MemoryMapInfo,
    kernel_stack: KernelStackInfo,
    acpi_rsdp: ?usize,
    framebuffer: ?FramebufferInfo,
};
