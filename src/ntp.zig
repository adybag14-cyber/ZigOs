const std = @import("std");

pub const packet_bytes: usize = 48;
pub const server_port: u16 = 123;
pub const unix_epoch_offset_seconds: u64 = 2_208_988_800;
pub const fixture_unix_seconds: u64 = 1_800_000_000;
pub const fixture_server_seconds: u32 = @intCast(unix_epoch_offset_seconds + fixture_unix_seconds);
pub const fixture_client_timestamp: u64 = (@as(u64, fixture_server_seconds - 1) << 32) | 0x40000000;
pub const fixture_server_timestamp: u64 = (@as(u64, fixture_server_seconds) << 32) | 0x80000000;

const mode_client: u8 = 3;
const mode_server: u8 = 4;
const version_4: u8 = 4;
const leap_alarm: u8 = 3;

pub const UnixTime = struct {
    seconds: u64,
    fraction: u32,
};

pub const ClockApplyResult = enum(u8) {
    accepted,
    stale,
};

pub const Clock = struct {
    synchronized: bool,
    unix_seconds: u64,
    unix_fraction: u32,
    stratum: u8,
    reference_id: [4]u8,
    accepted_samples: u64,
    stale_samples: u64,
};

pub const ProjectedClock = struct {
    clock: Clock,
    anchor_tick: u64,
    ticks_per_second: u64,
};

pub const Response = struct {
    leap_indicator: u8,
    version: u8,
    stratum: u8,
    poll: i8,
    precision: i8,
    root_delay: u32,
    root_dispersion: u32,
    reference_id: [4]u8,
    receive_timestamp: u64,
    transmit_timestamp: u64,
    unix_seconds: u64,
    unix_fraction: u32,
};

pub const QualityPolicy = struct {
    max_stratum: u8,
    max_root_delay: u32,
    max_root_dispersion: u32,
};

pub const QualityResult = enum(u8) {
    accepted,
    invalid_policy,
    stratum,
    root_delay,
    root_dispersion,
};

pub fn rootDelayMagnitude(root_delay: u32) u32 {
    const signed: i32 = @bitCast(root_delay);
    if (signed >= 0) return @intCast(signed);
    return @intCast(-@as(i64, signed));
}

pub fn evaluateQuality(response: Response, policy: QualityPolicy) QualityResult {
    if (policy.max_stratum == 0 or policy.max_stratum > 15) return .invalid_policy;
    if (response.stratum > policy.max_stratum) return .stratum;
    if (rootDelayMagnitude(response.root_delay) > policy.max_root_delay) return .root_delay;
    if (response.root_dispersion > policy.max_root_dispersion) return .root_dispersion;
    return .accepted;
}

pub fn readClock(clock: *const Clock) ?UnixTime {
    if (!clock.synchronized) return null;
    return .{ .seconds = clock.unix_seconds, .fraction = clock.unix_fraction };
}

pub fn applyResponse(clock: *Clock, response: Response) ClockApplyResult {
    if (clock.synchronized and !timeAfter(
        response.unix_seconds,
        response.unix_fraction,
        clock.unix_seconds,
        clock.unix_fraction,
    )) {
        clock.stale_samples +|= 1;
        return .stale;
    }
    clock.synchronized = true;
    clock.unix_seconds = response.unix_seconds;
    clock.unix_fraction = response.unix_fraction;
    clock.stratum = response.stratum;
    clock.reference_id = response.reference_id;
    clock.accepted_samples +|= 1;
    return .accepted;
}

fn timeAfter(
    candidate_seconds: u64,
    candidate_fraction: u32,
    current_seconds: u64,
    current_fraction: u32,
) bool {
    return candidate_seconds > current_seconds or
        (candidate_seconds == current_seconds and candidate_fraction > current_fraction);
}

pub fn readProjectedClockAt(projected: *const ProjectedClock, current_tick: u64) ?UnixTime {
    if (!projected.clock.synchronized or projected.ticks_per_second == 0 or
        current_tick < projected.anchor_tick)
    {
        return null;
    }
    const elapsed_ticks = current_tick - projected.anchor_tick;
    const elapsed_seconds = elapsed_ticks / projected.ticks_per_second;
    const remainder_ticks = elapsed_ticks % projected.ticks_per_second;
    const fraction_increment_u128 =
        (@as(u128, remainder_ticks) << 32) / projected.ticks_per_second;
    const fraction_sum = @as(u64, projected.clock.unix_fraction) +
        @as(u64, @intCast(fraction_increment_u128));
    const fraction_carry = fraction_sum >> 32;
    const total_increment = elapsed_seconds +| fraction_carry;
    if (total_increment > std.math.maxInt(u64) - projected.clock.unix_seconds) return null;
    return .{
        .seconds = projected.clock.unix_seconds + total_increment,
        .fraction = @truncate(fraction_sum),
    };
}

pub fn applyResponseAt(
    projected: *ProjectedClock,
    response: Response,
    monotonic_tick: u64,
    ticks_per_second: u64,
) ?ClockApplyResult {
    if (ticks_per_second == 0) return null;
    if (projected.clock.synchronized) {
        const current = readProjectedClockAt(projected, monotonic_tick) orelse return null;
        if (!timeAfter(
            response.unix_seconds,
            response.unix_fraction,
            current.seconds,
            current.fraction,
        )) {
            projected.clock.stale_samples +|= 1;
            return .stale;
        }
    }
    projected.clock.synchronized = true;
    projected.clock.unix_seconds = response.unix_seconds;
    projected.clock.unix_fraction = response.unix_fraction;
    projected.clock.stratum = response.stratum;
    projected.clock.reference_id = response.reference_id;
    projected.clock.accepted_samples +|= 1;
    projected.anchor_tick = monotonic_tick;
    projected.ticks_per_second = ticks_per_second;
    return .accepted;
}

pub fn unixTimeToTimestamp(time: UnixTime) ?u64 {
    const maximum_unix_seconds = std.math.maxInt(u32) - unix_epoch_offset_seconds;
    if (time.seconds > maximum_unix_seconds) return null;
    const ntp_seconds = time.seconds + unix_epoch_offset_seconds;
    return (ntp_seconds << 32) | time.fraction;
}

pub fn projectedTimestampAt(projected: *const ProjectedClock, current_tick: u64) ?u64 {
    const time = readProjectedClockAt(projected, current_tick) orelse return null;
    return unixTimeToTimestamp(time);
}
pub fn buildClientRequest(buffer: []u8, transmit_timestamp: u64) ?[]const u8 {
    if (buffer.len < packet_bytes or transmit_timestamp == 0) return null;
    @memset(buffer[0..packet_bytes], 0);
    buffer[0] = (version_4 << 3) | mode_client;
    writeNetwork64(buffer, 40, transmit_timestamp);
    return buffer[0..packet_bytes];
}

pub fn buildServerResponse(
    buffer: []u8,
    originate_timestamp: u64,
    receive_timestamp: u64,
    transmit_timestamp: u64,
) ?[]const u8 {
    if (buffer.len < packet_bytes or originate_timestamp == 0 or
        receive_timestamp == 0 or transmit_timestamp == 0 or
        receive_timestamp > transmit_timestamp)
    {
        return null;
    }
    @memset(buffer[0..packet_bytes], 0);
    buffer[0] = (version_4 << 3) | mode_server;
    buffer[1] = 2;
    buffer[2] = 6;
    buffer[3] = @bitCast(@as(i8, -20));
    writeNetwork32(buffer, 4, 0x00010000);
    writeNetwork32(buffer, 8, 0x00008000);
    @memcpy(buffer[12..16], "LOCL");
    writeNetwork64(buffer, 16, transmit_timestamp - (@as(u64, 2) << 32));
    writeNetwork64(buffer, 24, originate_timestamp);
    writeNetwork64(buffer, 32, receive_timestamp);
    writeNetwork64(buffer, 40, transmit_timestamp);
    return buffer[0..packet_bytes];
}

pub fn parseServerResponse(message: []const u8, expected_originate_timestamp: u64) ?Response {
    if (message.len < packet_bytes or expected_originate_timestamp == 0) return null;
    const leap_indicator = message[0] >> 6;
    const version = (message[0] >> 3) & 0x07;
    const mode = message[0] & 0x07;
    const stratum = message[1];
    if (leap_indicator == leap_alarm or (version != 3 and version != 4) or
        mode != mode_server or stratum == 0 or stratum > 15)
    {
        return null;
    }
    const originate_timestamp = readNetwork64(message, 24);
    const receive_timestamp = readNetwork64(message, 32);
    const transmit_timestamp = readNetwork64(message, 40);
    if (originate_timestamp != expected_originate_timestamp or
        receive_timestamp == 0 or transmit_timestamp == 0 or
        receive_timestamp > transmit_timestamp)
    {
        return null;
    }
    const ntp_seconds: u64 = @truncate(transmit_timestamp >> 32);
    if (ntp_seconds < unix_epoch_offset_seconds) return null;
    var reference_id: [4]u8 = undefined;
    @memcpy(&reference_id, message[12..16]);
    return .{
        .leap_indicator = leap_indicator,
        .version = version,
        .stratum = stratum,
        .poll = @bitCast(message[2]),
        .precision = @bitCast(message[3]),
        .root_delay = readNetwork32(message, 4),
        .root_dispersion = readNetwork32(message, 8),
        .reference_id = reference_id,
        .receive_timestamp = receive_timestamp,
        .transmit_timestamp = transmit_timestamp,
        .unix_seconds = ntp_seconds - unix_epoch_offset_seconds,
        .unix_fraction = @truncate(transmit_timestamp),
    };
}

fn writeNetwork32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value >> 24);
    bytes[offset + 1] = @truncate(value >> 16);
    bytes[offset + 2] = @truncate(value >> 8);
    bytes[offset + 3] = @truncate(value);
}

fn writeNetwork64(bytes: []u8, offset: usize, value: u64) void {
    writeNetwork32(bytes, offset, @truncate(value >> 32));
    writeNetwork32(bytes, offset + 4, @truncate(value));
}

fn readNetwork32(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}

fn readNetwork64(bytes: []const u8, offset: usize) u64 {
    return (@as(u64, readNetwork32(bytes, offset)) << 32) |
        readNetwork32(bytes, offset + 4);
}

comptime {
    if (packet_bytes != 48) @compileError("NTP base packet size changed unexpectedly");
    if (fixture_server_seconds <= unix_epoch_offset_seconds) @compileError("NTP fixture must follow the Unix epoch");
}
