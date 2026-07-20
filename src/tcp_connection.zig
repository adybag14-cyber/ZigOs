const tcp = @import("tcp.zig");

pub const State = enum(u8) {
    closed,
    syn_sent,
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
    unsupported_simultaneous_open,
};

pub const ActionKind = enum(u8) {
    none,
    send_syn,
    send_ack,
    connection_reset,
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

pub const ControlBlock = struct {
    state: State,
    initial_send_sequence: u32,
    send_unacknowledged: u32,
    send_next: u32,
    receive_next: u32,
    send_window: u16,
    receive_window: u16,
    resets: u32,
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

    return .{
        .accepted = true,
        .previous_state = previous,
        .state = control.state,
        .action = .send_syn,
        .outbound = .{
            .sequence_number = initial_sequence,
            .acknowledgement_number = 0,
            .flags = tcp.flag_syn,
            .window_size = control.receive_window,
        },
        .rejection = .none,
    };
}

pub fn handleSegment(control: *ControlBlock, segment: SegmentView) Transition {
    return switch (control.state) {
        .syn_sent => handleSynSent(control, segment),
        .established => handleEstablishedReset(control, segment),
        else => reject(control.state, .invalid_state),
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
        return .{
            .accepted = true,
            .previous_state = previous,
            .state = control.state,
            .action = .connection_reset,
            .outbound = null,
            .rejection = .none,
        };
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
    return .{
        .accepted = true,
        .previous_state = previous,
        .state = control.state,
        .action = .send_ack,
        .outbound = .{
            .sequence_number = control.send_next,
            .acknowledgement_number = control.receive_next,
            .flags = tcp.flag_ack,
            .window_size = control.receive_window,
        },
        .rejection = .none,
    };
}

fn handleEstablishedReset(control: *ControlBlock, segment: SegmentView) Transition {
    const previous = control.state;
    if (!hasFlag(segment.flags, tcp.flag_rst)) return reject(previous, .invalid_segment);
    if (hasFlag(segment.flags, tcp.flag_syn) or segment.payload_length != 0) {
        return reject(previous, .invalid_segment);
    }
    if (segment.sequence_number != control.receive_next) {
        return reject(previous, .unexpected_sequence);
    }
    control.state = .reset;
    control.resets +|= 1;
    return .{
        .accepted = true,
        .previous_state = previous,
        .state = control.state,
        .action = .connection_reset,
        .outbound = null,
        .rejection = .none,
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

comptime {
    if (tcp.flag_syn != 0x002) @compileError("TCP SYN flag changed unexpectedly");
    if (tcp.flag_ack != 0x010) @compileError("TCP ACK flag changed unexpectedly");
    if (tcp.flag_rst != 0x004) @compileError("TCP RST flag changed unexpectedly");
}
