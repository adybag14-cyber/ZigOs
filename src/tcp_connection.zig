const std = @import("std");
const tcp = @import("tcp.zig");

pub const State = enum(u8) {
    closed,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    time_wait,
    reset,
    timed_out,
};

pub const RejectReason = enum(u8) {
    none,
    invalid_state,
    invalid_segment,
    invalid_acknowledgement,
    unexpected_sequence,
    duplicate_segment,
    segment_outside_window,
    unsupported_simultaneous_open,
    invalid_retransmission_policy,
};

pub const ActionKind = enum(u8) {
    none,
    send_syn,
    send_syn_ack,
    send_ack,
    send_fin_ack,
    connection_reset,
    connection_closed,
};

pub const TimerReason = enum(u8) {
    none,
    invalid_state,
    timer_inactive,
    backward_tick,
    before_deadline,
};

pub const TimerAction = enum(u8) {
    none,
    retransmit_syn,
    retransmit_syn_ack,
    timed_out,
};

pub const RetransmissionPolicy = struct {
    initial_timeout_ticks: u64,
    maximum_timeout_ticks: u64,
    maximum_retries: u8,

    pub fn valid(self: RetransmissionPolicy) bool {
        return self.initial_timeout_ticks != 0 and
            self.maximum_timeout_ticks >= self.initial_timeout_ticks and
            self.maximum_retries != 0;
    }
};

pub const SegmentView = struct {
    sequence_number: u32,
    acknowledgement_number: u32,
    flags: u9,
    window_size: u16,
    payload_length: u16 = 0,
};

pub const OutboundSegment = struct {
    sequence_number: u32,
    acknowledgement_number: u32,
    flags: u9,
    window_size: u16,
};

pub const Transition = struct {
    accepted: bool,
    previous_state: State,
    state: State,
    action: ActionKind,
    outbound: ?OutboundSegment,
    rejection: RejectReason,
};

pub const TimerResult = struct {
    action: TimerAction,
    previous_state: State,
    state: State,
    reason: TimerReason,
    tick: u64,
    previous_deadline: u64,
    next_deadline: u64,
    interval: u64,
    retransmissions: u8,
    outbound: ?OutboundSegment,
};

pub const ControlBlock = struct {
    state: State,
    initial_send_sequence: u32,
    send_unacknowledged: u32,
    send_next: u32,
    receive_next: u32,
    send_window: u16,
    receive_window: u16,
    resets: u32,
    bytes_received: u64,
    bytes_sent: u64,
    fins_received: u32,
    fins_sent: u32,
    retransmission_policy: RetransmissionPolicy,
    retransmission_active: bool,
    retransmission_deadline: u64,
    retransmission_interval: u64,
    retransmissions: u8,
    last_timer_tick: u64,
};

pub fn init(receive_window: u16) ?ControlBlock {
    if (receive_window == 0) return null;
    return .{
        .state = .closed,
        .initial_send_sequence = 0,
        .send_unacknowledged = 0,
        .send_next = 0,
        .receive_next = 0,
        .send_window = 0,
        .receive_window = receive_window,
        .resets = 0,
        .bytes_received = 0,
        .bytes_sent = 0,
        .fins_received = 0,
        .fins_sent = 0,
        .retransmission_policy = .{
            .initial_timeout_ticks = 0,
            .maximum_timeout_ticks = 0,
            .maximum_retries = 0,
        },
        .retransmission_active = false,
        .retransmission_deadline = 0,
        .retransmission_interval = 0,
        .retransmissions = 0,
        .last_timer_tick = 0,
    };
}

pub fn beginActiveOpen(control: *ControlBlock, initial_sequence: u32) Transition {
    const previous = control.state;
    if (previous != .closed) return reject(previous, .invalid_state);

    control.state = .syn_sent;
    control.initial_send_sequence = initial_sequence;
    control.send_unacknowledged = initial_sequence;
    control.send_next = initial_sequence +% 1;
    control.receive_next = 0;
    control.send_window = 0;
    control.resets = 0;
    control.bytes_received = 0;
    control.bytes_sent = 0;
    control.fins_received = 0;
    control.fins_sent = 0;
    control.retransmission_active = false;
    control.retransmission_deadline = 0;
    control.retransmission_interval = 0;
    control.retransmissions = 0;
    control.last_timer_tick = 0;

    return .{
        .accepted = true,
        .previous_state = previous,
        .state = control.state,
        .action = .send_syn,
        .outbound = makeSyn(control),
        .rejection = .none,
    };
}

pub fn beginActiveOpenAt(
    control: *ControlBlock,
    initial_sequence: u32,
    tick: u64,
    policy: RetransmissionPolicy,
) Transition {
    if (!policy.valid()) return reject(control.state, .invalid_retransmission_policy);
    const transition = beginActiveOpen(control, initial_sequence);
    if (!transition.accepted) return transition;
    control.retransmission_policy = policy;
    control.retransmission_active = true;
    control.retransmission_interval = policy.initial_timeout_ticks;
    control.retransmission_deadline = saturatingAdd(tick, policy.initial_timeout_ticks);
    control.retransmissions = 0;
    control.last_timer_tick = tick;
    return transition;
}

pub fn beginPassiveOpenAt(
    control: *ControlBlock,
    initial_sequence: u32,
    segment: SegmentView,
    tick: u64,
    policy: RetransmissionPolicy,
) Transition {
    const previous = control.state;
    if (previous != .closed) return reject(previous, .invalid_state);
    if (!policy.valid()) return reject(previous, .invalid_retransmission_policy);
    if (segment.flags != tcp.flag_syn or segment.payload_length != 0) {
        return reject(previous, .invalid_segment);
    }

    control.state = .syn_received;
    control.initial_send_sequence = initial_sequence;
    control.send_unacknowledged = initial_sequence;
    control.send_next = initial_sequence +% 1;
    control.receive_next = segment.sequence_number +% 1;
    control.send_window = segment.window_size;
    control.resets = 0;
    control.bytes_received = 0;
    control.bytes_sent = 0;
    control.fins_received = 0;
    control.fins_sent = 0;
    control.retransmission_policy = policy;
    control.retransmission_active = true;
    control.retransmission_interval = policy.initial_timeout_ticks;
    control.retransmission_deadline = saturatingAdd(tick, policy.initial_timeout_ticks);
    control.retransmissions = 0;
    control.last_timer_tick = tick;

    return accepted(control, previous, .send_syn_ack, makeSynAck(control));
}

pub fn applicationSendReady(control: *const ControlBlock) bool {
    return control.state == .established and control.send_unacknowledged == control.send_next and control.send_window != 0;
}

pub fn beginApplicationSend(control: *ControlBlock, payload_length: u16) ?OutboundSegment {
    if (payload_length == 0 or !applicationSendReady(control) or payload_length > control.send_window) return null;
    const outbound = OutboundSegment{
        .sequence_number = control.send_next,
        .acknowledgement_number = control.receive_next,
        .flags = tcp.flag_psh | tcp.flag_ack,
        .window_size = control.receive_window,
    };
    control.send_next +%= payload_length;
    control.bytes_sent +|= payload_length;
    return outbound;
}

pub fn beginClose(control: *ControlBlock) Transition {
    const previous = control.state;
    const next_state: State = switch (previous) {
        .established => .fin_wait_1,
        .close_wait => .last_ack,
        else => return reject(previous, .invalid_state),
    };
    const outbound = OutboundSegment{
        .sequence_number = control.send_next,
        .acknowledgement_number = control.receive_next,
        .flags = tcp.flag_fin | tcp.flag_ack,
        .window_size = control.receive_window,
    };
    control.send_next +%= 1;
    control.fins_sent +|= 1;
    control.state = next_state;
    return .{
        .accepted = true,
        .previous_state = previous,
        .state = control.state,
        .action = .send_fin_ack,
        .outbound = outbound,
        .rejection = .none,
    };
}

pub fn expireTimeWait(control: *ControlBlock) Transition {
    const previous = control.state;
    if (previous != .time_wait) return reject(previous, .invalid_state);
    control.state = .closed;
    return .{
        .accepted = true,
        .previous_state = previous,
        .state = control.state,
        .action = .connection_closed,
        .outbound = null,
        .rejection = .none,
    };
}

pub fn handleSegment(control: *ControlBlock, segment: SegmentView) Transition {
    return switch (control.state) {
        .syn_sent => handleSynSent(control, segment),
        .syn_received => handleSynReceived(control, segment),
        .established => handleEstablished(control, segment),
        .fin_wait_1 => handleFinWait1(control, segment),
        .fin_wait_2 => handleFinWait2(control, segment),
        .close_wait => handleCloseWait(control, segment),
        .last_ack => handleLastAck(control, segment),
        .time_wait => handleTimeWait(control, segment),
        else => reject(control.state, .invalid_state),
    };
}

pub fn onTimer(control: *ControlBlock, tick: u64) TimerResult {
    const previous_state = control.state;
    const previous_deadline = control.retransmission_deadline;
    if (control.state != .syn_sent and control.state != .syn_received) {
        return timerNoop(control, tick, previous_state, previous_deadline, .invalid_state);
    }
    if (!control.retransmission_active) {
        return timerNoop(control, tick, previous_state, previous_deadline, .timer_inactive);
    }
    if (tick < control.last_timer_tick) {
        return timerNoop(control, tick, previous_state, previous_deadline, .backward_tick);
    }
    if (tick < control.retransmission_deadline) {
        return timerNoop(control, tick, previous_state, previous_deadline, .before_deadline);
    }

    if (control.retransmissions >= control.retransmission_policy.maximum_retries) {
        control.state = .timed_out;
        control.retransmission_active = false;
        control.last_timer_tick = tick;
        return .{
            .action = .timed_out,
            .previous_state = previous_state,
            .state = control.state,
            .reason = .none,
            .tick = tick,
            .previous_deadline = previous_deadline,
            .next_deadline = previous_deadline,
            .interval = control.retransmission_interval,
            .retransmissions = control.retransmissions,
            .outbound = null,
        };
    }

    control.retransmissions +|= 1;
    control.retransmission_interval = nextRetransmissionInterval(
        control.retransmission_interval,
        control.retransmission_policy.maximum_timeout_ticks,
    );
    control.retransmission_deadline = saturatingAdd(tick, control.retransmission_interval);
    control.last_timer_tick = tick;
    return .{
        .action = if (previous_state == .syn_sent) .retransmit_syn else .retransmit_syn_ack,
        .previous_state = previous_state,
        .state = control.state,
        .reason = .none,
        .tick = tick,
        .previous_deadline = previous_deadline,
        .next_deadline = control.retransmission_deadline,
        .interval = control.retransmission_interval,
        .retransmissions = control.retransmissions,
        .outbound = if (previous_state == .syn_sent) makeSyn(control) else makeSynAck(control),
    };
}

fn handleSynSent(control: *ControlBlock, segment: SegmentView) Transition {
    const previous = control.state;
    const has_syn = hasFlag(segment.flags, tcp.flag_syn);
    const has_ack = hasFlag(segment.flags, tcp.flag_ack);
    const has_rst = hasFlag(segment.flags, tcp.flag_rst);

    if (has_rst) {
        if (has_syn or !has_ack or segment.payload_length != 0) {
            return reject(previous, .invalid_segment);
        }
        if (segment.acknowledgement_number != control.send_next) {
            return reject(previous, .invalid_acknowledgement);
        }
        control.send_unacknowledged = segment.acknowledgement_number;
        control.state = .reset;
        control.resets +|= 1;
        stopRetransmission(control);
        return accepted(control, previous, .connection_reset, null);
    }

    if (!has_syn) return reject(previous, .invalid_segment);
    if (!has_ack) return reject(previous, .unsupported_simultaneous_open);
    if (hasFlag(segment.flags, tcp.flag_fin) or segment.payload_length != 0) {
        return reject(previous, .invalid_segment);
    }
    if (segment.acknowledgement_number != control.send_next) {
        return reject(previous, .invalid_acknowledgement);
    }

    control.send_unacknowledged = segment.acknowledgement_number;
    control.receive_next = segment.sequence_number +% 1;
    control.send_window = segment.window_size;
    control.state = .established;
    stopRetransmission(control);
    return accepted(control, previous, .send_ack, makeAck(control));
}

fn handleSynReceived(control: *ControlBlock, segment: SegmentView) Transition {
    const previous = control.state;
    if (segment.flags == tcp.flag_syn and segment.payload_length == 0) {
        if (segment.sequence_number +% 1 != control.receive_next) {
            return reject(previous, .unexpected_sequence);
        }
        return accepted(control, previous, .send_syn_ack, makeSynAck(control));
    }
    if (hasFlag(segment.flags, tcp.flag_rst)) return handleSynchronizedReset(control, segment);
    if (segment.flags != tcp.flag_ack or segment.payload_length != 0) {
        return reject(previous, .invalid_segment);
    }
    if (segment.sequence_number != control.receive_next) {
        return reject(previous, .unexpected_sequence);
    }
    if (segment.acknowledgement_number != control.send_next) {
        return reject(previous, .invalid_acknowledgement);
    }
    control.send_unacknowledged = segment.acknowledgement_number;
    control.send_window = segment.window_size;
    control.state = .established;
    stopRetransmission(control);
    return accepted(control, previous, .none, null);
}

fn handleEstablished(control: *ControlBlock, segment: SegmentView) Transition {
    const previous = control.state;
    if (hasFlag(segment.flags, tcp.flag_rst)) return handleSynchronizedReset(control, segment);
    if (hasFlag(segment.flags, tcp.flag_syn) or !hasFlag(segment.flags, tcp.flag_ack)) {
        return reject(previous, .invalid_segment);
    }
    if (segment.acknowledgement_number != control.send_next) {
        return reject(previous, .invalid_acknowledgement);
    }
    if (segment.payload_length > control.receive_window) {
        return reject(previous, .segment_outside_window);
    }
    if (segment.sequence_number != control.receive_next) {
        const reason: RejectReason = if (sequenceBefore(segment.sequence_number, control.receive_next))
            .duplicate_segment
        else
            .unexpected_sequence;
        return acknowledgeRejection(control, previous, reason);
    }

    control.send_unacknowledged = segment.acknowledgement_number;
    control.send_window = segment.window_size;
    if (segment.payload_length != 0) {
        control.receive_next +%= segment.payload_length;
        control.bytes_received +|= segment.payload_length;
    }
    if (hasFlag(segment.flags, tcp.flag_fin)) {
        control.receive_next +%= 1;
        control.fins_received +|= 1;
        control.state = .close_wait;
        return accepted(control, previous, .send_ack, makeAck(control));
    }
    if (segment.payload_length != 0) return accepted(control, previous, .send_ack, makeAck(control));
    return accepted(control, previous, .none, null);
}

fn handleFinWait1(control: *ControlBlock, segment: SegmentView) Transition {
    const previous = control.state;
    if (hasFlag(segment.flags, tcp.flag_rst)) return handleSynchronizedReset(control, segment);
    if (hasFlag(segment.flags, tcp.flag_syn) or !hasFlag(segment.flags, tcp.flag_ack) or
        segment.payload_length != 0)
    {
        return reject(previous, .invalid_segment);
    }
    if (segment.acknowledgement_number != control.send_next) {
        return reject(previous, .invalid_acknowledgement);
    }
    if (segment.sequence_number != control.receive_next) {
        return acknowledgeRejection(control, previous, .unexpected_sequence);
    }
    control.send_unacknowledged = segment.acknowledgement_number;
    control.send_window = segment.window_size;
    if (hasFlag(segment.flags, tcp.flag_fin)) {
        control.receive_next +%= 1;
        control.fins_received +|= 1;
        control.state = .time_wait;
        return accepted(control, previous, .send_ack, makeAck(control));
    }
    control.state = .fin_wait_2;
    return accepted(control, previous, .none, null);
}

fn handleFinWait2(control: *ControlBlock, segment: SegmentView) Transition {
    const previous = control.state;
    if (hasFlag(segment.flags, tcp.flag_rst)) return handleSynchronizedReset(control, segment);
    if (hasFlag(segment.flags, tcp.flag_syn) or !hasFlag(segment.flags, tcp.flag_ack) or
        segment.payload_length != 0)
    {
        return reject(previous, .invalid_segment);
    }
    if (segment.acknowledgement_number != control.send_next) {
        return reject(previous, .invalid_acknowledgement);
    }
    if (!hasFlag(segment.flags, tcp.flag_fin)) {
        if (segment.sequence_number != control.receive_next) {
            return acknowledgeRejection(control, previous, .unexpected_sequence);
        }
        control.send_unacknowledged = segment.acknowledgement_number;
        control.send_window = segment.window_size;
        return accepted(control, previous, .none, null);
    }
    if (segment.sequence_number != control.receive_next) {
        const reason: RejectReason = if (segment.sequence_number +% 1 == control.receive_next)
            .duplicate_segment
        else
            .unexpected_sequence;
        return acknowledgeRejection(control, previous, reason);
    }
    control.send_unacknowledged = segment.acknowledgement_number;
    control.send_window = segment.window_size;
    control.receive_next +%= 1;
    control.fins_received +|= 1;
    control.state = .time_wait;
    return accepted(control, previous, .send_ack, makeAck(control));
}

fn handleCloseWait(control: *ControlBlock, segment: SegmentView) Transition {
    if (hasFlag(segment.flags, tcp.flag_rst)) return handleSynchronizedReset(control, segment);
    return reject(control.state, .invalid_segment);
}

fn handleLastAck(control: *ControlBlock, segment: SegmentView) Transition {
    const previous = control.state;
    if (hasFlag(segment.flags, tcp.flag_rst)) return handleSynchronizedReset(control, segment);
    if (hasFlag(segment.flags, tcp.flag_syn) or hasFlag(segment.flags, tcp.flag_fin) or
        !hasFlag(segment.flags, tcp.flag_ack) or segment.payload_length != 0)
    {
        return reject(previous, .invalid_segment);
    }
    if (segment.acknowledgement_number != control.send_next) {
        return reject(previous, .invalid_acknowledgement);
    }
    if (segment.sequence_number != control.receive_next) {
        return acknowledgeRejection(control, previous, .unexpected_sequence);
    }
    control.send_unacknowledged = segment.acknowledgement_number;
    control.send_window = segment.window_size;
    control.state = .closed;
    return accepted(control, previous, .connection_closed, null);
}

fn handleTimeWait(control: *ControlBlock, segment: SegmentView) Transition {
    if (hasFlag(segment.flags, tcp.flag_rst)) return handleSynchronizedReset(control, segment);
    if (hasFlag(segment.flags, tcp.flag_fin) and hasFlag(segment.flags, tcp.flag_ack) and
        segment.payload_length == 0 and segment.sequence_number +% 1 == control.receive_next and
        segment.acknowledgement_number == control.send_next)
    {
        return acknowledgeRejection(control, control.state, .duplicate_segment);
    }
    return reject(control.state, .invalid_segment);
}

fn handleSynchronizedReset(control: *ControlBlock, segment: SegmentView) Transition {
    const previous = control.state;
    if (hasFlag(segment.flags, tcp.flag_syn) or segment.payload_length != 0) {
        return reject(previous, .invalid_segment);
    }
    if (segment.sequence_number != control.receive_next) {
        return reject(previous, .unexpected_sequence);
    }
    control.state = .reset;
    control.resets +|= 1;
    stopRetransmission(control);
    return accepted(control, previous, .connection_reset, null);
}

fn makeSyn(control: *const ControlBlock) OutboundSegment {
    return .{
        .sequence_number = control.initial_send_sequence,
        .acknowledgement_number = 0,
        .flags = tcp.flag_syn,
        .window_size = control.receive_window,
    };
}

fn makeSynAck(control: *const ControlBlock) OutboundSegment {
    return .{
        .sequence_number = control.initial_send_sequence,
        .acknowledgement_number = control.receive_next,
        .flags = tcp.flag_syn | tcp.flag_ack,
        .window_size = control.receive_window,
    };
}

fn makeAck(control: *const ControlBlock) OutboundSegment {
    return .{
        .sequence_number = control.send_next,
        .acknowledgement_number = control.receive_next,
        .flags = tcp.flag_ack,
        .window_size = control.receive_window,
    };
}

fn stopRetransmission(control: *ControlBlock) void {
    control.retransmission_active = false;
}

fn accepted(
    control: *const ControlBlock,
    previous: State,
    action: ActionKind,
    outbound: ?OutboundSegment,
) Transition {
    return .{
        .accepted = true,
        .previous_state = previous,
        .state = control.state,
        .action = action,
        .outbound = outbound,
        .rejection = .none,
    };
}

fn acknowledgeRejection(
    control: *const ControlBlock,
    previous: State,
    reason: RejectReason,
) Transition {
    return .{
        .accepted = false,
        .previous_state = previous,
        .state = control.state,
        .action = .send_ack,
        .outbound = makeAck(control),
        .rejection = reason,
    };
}

fn timerNoop(
    control: *const ControlBlock,
    tick: u64,
    previous_state: State,
    previous_deadline: u64,
    reason: TimerReason,
) TimerResult {
    return .{
        .action = .none,
        .previous_state = previous_state,
        .state = control.state,
        .reason = reason,
        .tick = tick,
        .previous_deadline = previous_deadline,
        .next_deadline = control.retransmission_deadline,
        .interval = control.retransmission_interval,
        .retransmissions = control.retransmissions,
        .outbound = null,
    };
}

fn reject(state: State, reason: RejectReason) Transition {
    return .{
        .accepted = false,
        .previous_state = state,
        .state = state,
        .action = .none,
        .outbound = null,
        .rejection = reason,
    };
}

pub fn hasFlag(flags: u9, flag: u9) bool {
    return (flags & flag) != 0;
}

pub fn sequenceBefore(lhs: u32, rhs: u32) bool {
    return @as(i32, @bitCast(lhs -% rhs)) < 0;
}

pub fn sequenceAfter(lhs: u32, rhs: u32) bool {
    return sequenceBefore(rhs, lhs);
}

pub fn sequenceBetweenInclusive(value: u32, first: u32, last: u32) bool {
    return !sequenceBefore(value, first) and !sequenceAfter(value, last);
}

pub fn nextRetransmissionInterval(current: u64, maximum: u64) u64 {
    if (current >= maximum) return maximum;
    const doubled = std.math.mul(u64, current, 2) catch return maximum;
    return @min(doubled, maximum);
}

pub fn saturatingAdd(lhs: u64, rhs: u64) u64 {
    return std.math.add(u64, lhs, rhs) catch std.math.maxInt(u64);
}

test "passive open completes SYN SYN-ACK ACK and replays duplicate SYN" {
    var control = init(32_768).?;
    const policy = RetransmissionPolicy{ .initial_timeout_ticks = 10, .maximum_timeout_ticks = 40, .maximum_retries = 3 };
    const syn = SegmentView{ .sequence_number = 0x1020_3040, .acknowledgement_number = 0, .flags = tcp.flag_syn, .window_size = 24_000 };
    const opened = beginPassiveOpenAt(&control, 0x5060_7080, syn, 100, policy);
    try std.testing.expect(opened.accepted);
    try std.testing.expectEqual(State.syn_received, control.state);
    try std.testing.expectEqual(ActionKind.send_syn_ack, opened.action);
    try std.testing.expectEqual(@as(u32, 0x1020_3041), control.receive_next);
    try std.testing.expectEqual(tcp.flag_syn | tcp.flag_ack, opened.outbound.?.flags);

    const duplicate = handleSegment(&control, syn);
    try std.testing.expect(duplicate.accepted);
    try std.testing.expectEqual(State.syn_received, control.state);
    try std.testing.expectEqual(ActionKind.send_syn_ack, duplicate.action);

    const ack = handleSegment(&control, .{
        .sequence_number = control.receive_next,
        .acknowledgement_number = control.send_next,
        .flags = tcp.flag_ack,
        .window_size = 30_000,
    });
    try std.testing.expect(ack.accepted);
    try std.testing.expectEqual(State.established, control.state);
    try std.testing.expect(!control.retransmission_active);

    const retained_ack = handleSegment(&control, .{
        .sequence_number = control.receive_next,
        .acknowledgement_number = control.send_next,
        .flags = tcp.flag_ack,
        .window_size = 31_000,
    });
    try std.testing.expect(retained_ack.accepted);
    try std.testing.expectEqual(State.established, control.state);
    try std.testing.expectEqual(@as(u16, 31_000), control.send_window);
    try std.testing.expect(applicationSendReady(&control));

    const data_sequence = control.send_next;
    const data = beginApplicationSend(&control, 8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(data_sequence, data.sequence_number);
    try std.testing.expectEqual(control.receive_next, data.acknowledgement_number);
    try std.testing.expectEqual(tcp.flag_psh | tcp.flag_ack, data.flags);
    try std.testing.expectEqual(data_sequence +% 8, control.send_next);
    try std.testing.expectEqual(@as(u64, 8), control.bytes_sent);
    try std.testing.expect(!applicationSendReady(&control));
    try std.testing.expect(beginApplicationSend(&control, 1) == null);

    const data_ack = handleSegment(&control, .{
        .sequence_number = control.receive_next,
        .acknowledgement_number = control.send_next,
        .flags = tcp.flag_ack,
        .window_size = 30_500,
    });
    try std.testing.expect(data_ack.accepted);
    try std.testing.expectEqual(control.send_next, control.send_unacknowledged);
    try std.testing.expectEqual(@as(u16, 30_500), control.send_window);
    try std.testing.expect(applicationSendReady(&control));
    try std.testing.expect(beginApplicationSend(&control, 30_501) == null);

    const zero_window_ack = handleSegment(&control, .{
        .sequence_number = control.receive_next,
        .acknowledgement_number = control.send_next,
        .flags = tcp.flag_ack,
        .window_size = 0,
    });
    try std.testing.expect(zero_window_ack.accepted);
    try std.testing.expect(!applicationSendReady(&control));
    try std.testing.expect(beginApplicationSend(&control, 1) == null);

    const reopened_window_ack = handleSegment(&control, .{
        .sequence_number = control.receive_next,
        .acknowledgement_number = control.send_next,
        .flags = tcp.flag_ack,
        .window_size = 30_500,
    });
    try std.testing.expect(reopened_window_ack.accepted);
    try std.testing.expect(applicationSendReady(&control));

    const wrong_reset = handleSegment(&control, .{
        .sequence_number = control.receive_next +% 1,
        .acknowledgement_number = control.send_next,
        .flags = tcp.flag_rst,
        .window_size = 0,
    });
    try std.testing.expect(!wrong_reset.accepted);
    try std.testing.expectEqual(RejectReason.unexpected_sequence, wrong_reset.rejection);
    try std.testing.expectEqual(State.established, control.state);

    const reset = handleSegment(&control, .{
        .sequence_number = control.receive_next,
        .acknowledgement_number = control.send_next,
        .flags = tcp.flag_rst,
        .window_size = 0,
    });
    try std.testing.expect(reset.accepted);
    try std.testing.expectEqual(ActionKind.connection_reset, reset.action);
    try std.testing.expectEqual(State.reset, control.state);
    try std.testing.expectEqual(@as(u32, 1), control.resets);
}

test "passive SYN-ACK retransmission is bounded" {
    var control = init(16_384).?;
    const policy = RetransmissionPolicy{ .initial_timeout_ticks = 5, .maximum_timeout_ticks = 20, .maximum_retries = 2 };
    const syn = SegmentView{ .sequence_number = 99, .acknowledgement_number = 0, .flags = tcp.flag_syn, .window_size = 4096 };
    try std.testing.expect(beginPassiveOpenAt(&control, 1234, syn, 50, policy).accepted);
    const first = onTimer(&control, 55);
    try std.testing.expectEqual(TimerAction.retransmit_syn_ack, first.action);
    try std.testing.expectEqual(tcp.flag_syn | tcp.flag_ack, first.outbound.?.flags);
    const second = onTimer(&control, first.next_deadline);
    try std.testing.expectEqual(TimerAction.retransmit_syn_ack, second.action);
    const timed_out = onTimer(&control, second.next_deadline);
    try std.testing.expectEqual(TimerAction.timed_out, timed_out.action);
    try std.testing.expectEqual(State.timed_out, control.state);
}

comptime {
    if (tcp.flag_syn != 0x002) @compileError("TCP SYN flag changed unexpectedly");
    if (tcp.flag_ack != 0x010) @compileError("TCP ACK flag changed unexpectedly");
    if (tcp.flag_rst != 0x004) @compileError("TCP RST flag changed unexpectedly");
    if (tcp.flag_fin != 0x001) @compileError("TCP FIN flag changed unexpectedly");
}
