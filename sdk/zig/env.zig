const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;

pub export fn zigos_main(
    argc: usize,
    _: [*]const usize,
    envp: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 1) {
        zigos.writeAll(2, "usage: env\r\n") catch {};
        return status_usage;
    }

    var index: usize = 0;
    while (index < zigos.constants.maximum_environment) : (index += 1) {
        if (envp[index] == 0) return status_success;
        const pointer: [*:0]const u8 = @ptrFromInt(envp[index]);
        const length = boundedEnvironmentLength(pointer) orelse {
            zigos.writeAll(2, "env: malformed environment\r\n") catch {};
            return status_failure;
        };
        const entry = pointer[0..length];
        if (!validEnvironmentEntry(entry)) {
            zigos.writeAll(2, "env: malformed environment\r\n") catch {};
            return status_failure;
        }
        zigos.writeAll(1, entry) catch return status_failure;
        zigos.writeAll(1, "\r\n") catch return status_failure;
    }

    if (envp[index] != 0) {
        zigos.writeAll(2, "env: too many environment entries\r\n") catch {};
        return status_failure;
    }
    return status_success;
}

fn boundedEnvironmentLength(value: [*:0]const u8) ?usize {
    var length: usize = 0;
    while (length <= zigos.constants.maximum_environment_bytes) : (length += 1) {
        if (value[length] == 0) return length;
    }
    return null;
}

fn validEnvironmentEntry(entry: []const u8) bool {
    if (entry.len == 0 or entry.len > zigos.constants.maximum_environment_bytes) return false;
    var separator: ?usize = null;
    for (entry, 0..) |byte, offset| {
        if (byte == 0) return false;
        if (byte == '=' and separator == null) separator = offset;
    }
    return if (separator) |offset| offset != 0 else false;
}
