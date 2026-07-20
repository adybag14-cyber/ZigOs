const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .x86) @compileError("legacy kernel requires the x86 target");
    if (builtin.os.tag != .freestanding) @compileError("legacy kernel requires a freestanding target");
}

pub export fn zigos_legacy_kernel_main() callconv(.c) noreturn {
    debugWrite("ZigOs i686 freestanding kernel image built\r\n");
    haltForever();
}

fn debugWrite(text: []const u8) void {
    for (text) |character| debugPutc(character);
}

fn debugPutc(character: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (character),
          [port] "{dx}" (@as(u16, 0x00E9)),
        : .{ .memory = true });
}

fn haltForever() noreturn {
    while (true) asm volatile ("hlt");
}
