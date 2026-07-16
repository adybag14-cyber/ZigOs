const amd64_machine: u16 = 0x8664;
const pe32_plus_magic: u16 = 0x020B;
const efi_application_subsystem: u16 = 10;

pub const Image = struct {
    pe_offset: u32,
    machine: u16,
    section_count: u16,
    optional_header_size: u16,
    optional_magic: u16,
    entry_point_rva: u32,
    image_base: u64,
    section_alignment: u32,
    file_alignment: u32,
    size_of_image: u32,
    size_of_headers: u32,
    checksum: u32,
    subsystem: u16,
    amd64: bool,
    pe32_plus: bool,
    efi_application: bool,
};

pub fn parse(first_bytes: []const u8) ?Image {
    if (first_bytes.len < 0x100) return null;
    if (read16(first_bytes, 0) != 0x5A4D) return null;

    const pe_offset = read32(first_bytes, 0x3C);
    const pe: usize = @intCast(pe_offset);
    if (pe > first_bytes.len - 24) return null;
    if (read32(first_bytes, pe) != 0x0000_4550) return null;

    const machine = read16(first_bytes, pe + 4);
    const section_count = read16(first_bytes, pe + 6);
    const optional_header_size = read16(first_bytes, pe + 20);
    const optional = pe + 24;
    if (optional_header_size < 112) return null;
    if (optional > first_bytes.len - optional_header_size) return null;

    const optional_magic = read16(first_bytes, optional);
    const subsystem = read16(first_bytes, optional + 68);
    return .{
        .pe_offset = pe_offset,
        .machine = machine,
        .section_count = section_count,
        .optional_header_size = optional_header_size,
        .optional_magic = optional_magic,
        .entry_point_rva = read32(first_bytes, optional + 16),
        .image_base = read64(first_bytes, optional + 24),
        .section_alignment = read32(first_bytes, optional + 32),
        .file_alignment = read32(first_bytes, optional + 36),
        .size_of_image = read32(first_bytes, optional + 56),
        .size_of_headers = read32(first_bytes, optional + 60),
        .checksum = read32(first_bytes, optional + 64),
        .subsystem = subsystem,
        .amd64 = machine == amd64_machine,
        .pe32_plus = optional_magic == pe32_plus_magic,
        .efi_application = subsystem == efi_application_subsystem,
    };
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, read16(bytes, offset)) | (@as(u32, read16(bytes, offset + 2)) << 16);
}

fn read64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, read32(bytes, offset)) | (@as(u64, read32(bytes, offset + 4)) << 32);
}
