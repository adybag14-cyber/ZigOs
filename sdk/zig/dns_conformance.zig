const zigos = @import("zigos.zig");
const dns = @import("dns.zig");

pub export fn zigos_main(
    argc: usize,
    _: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 1) return 0xD0;
    zigos.writeAll(1, "dns-sdk: start\r\n") catch return 0xD1;
    const server = dns.ipv4Address(.{ 10, 0, 2, 3 }, dns.dns_port);
    const resolution = dns.resolveA(server, "localhost", 200) catch return 0xD2;
    if (!equal(&resolution.address, &.{ 127, 0, 0, 1 }) or resolution.ttl_seconds == 0) return 0xD3;
    zigos.writeAll(1, "dns-sdk: userspace resolver localhost -> 127.0.0.1 passed\r\n") catch return 0xD4;
    return 0x5A;
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}
