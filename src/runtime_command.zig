const std = @import("std");

pub const maximum_line_length: usize = 256;
pub const maximum_token_length: usize = 63;
pub const maximum_arguments: usize = 12;
pub const maximum_pipeline_stages: usize = 4;
pub const maximum_history: usize = 16;
pub const maximum_environment: usize = 24;
pub const maximum_environment_value: usize = 95;

pub const Error = error{
    EmptyCommand,
    TooLong,
    TooManyArguments,
    TooManyStages,
    UnterminatedQuote,
    DanglingEscape,
    MissingRedirectionTarget,
    DuplicateRedirection,
    InvalidBackgroundPlacement,
    InvalidPipeline,
    InvalidVariableName,
    EnvironmentFull,
    VariableValueTooLong,
};

pub const Token = struct {
    bytes: [maximum_token_length + 1]u8 = @splat(0),
    length: u8 = 0,

    pub fn slice(self: *const Token) []const u8 {
        return self.bytes[0..self.length];
    }

    fn set(self: *Token, value: []const u8) Error!void {
        if (value.len > maximum_token_length) return Error.TooLong;
        self.* = .{};
        self.length = @intCast(value.len);
        @memcpy(self.bytes[0..value.len], value);
    }
};

pub const Stage = struct {
    arguments: [maximum_arguments]Token = @splat(.{}),
    count: usize = 0,

    pub fn command(self: *const Stage) ?[]const u8 {
        return if (self.count == 0) null else self.arguments[0].slice();
    }
};

const Redirection = enum { none, input, output, append };

pub const CommandLine = struct {
    stages: [maximum_pipeline_stages]Stage = @splat(.{}),
    stage_count: usize = 0,
    input_path: ?Token = null,
    output_path: ?Token = null,
    append_output: bool = false,
    background: bool = false,
};

pub const EnvironmentEntry = struct {
    used: bool = false,
    key: [maximum_token_length + 1]u8 = @splat(0),
    key_length: u8 = 0,
    value: [maximum_environment_value + 1]u8 = @splat(0),
    value_length: u8 = 0,

    pub fn keySlice(self: *const EnvironmentEntry) []const u8 {
        return self.key[0..self.key_length];
    }

    pub fn valueSlice(self: *const EnvironmentEntry) []const u8 {
        return self.value[0..self.value_length];
    }
};

pub const Environment = struct {
    entries: [maximum_environment]EnvironmentEntry = @splat(.{}),

    pub fn init() Environment {
        var env = Environment{};
        env.set("PATH", "/bin:/usr/bin") catch unreachable;
        env.set("HOME", "/home/root") catch unreachable;
        env.set("USER", "root") catch unreachable;
        env.set("SHELL", "/bin/zsh") catch unreachable;
        env.set("TERM", "zigos-serial") catch unreachable;
        return env;
    }

    pub fn set(self: *Environment, key: []const u8, value: []const u8) Error!void {
        if (!validVariableName(key)) return Error.InvalidVariableName;
        if (value.len > maximum_environment_value) return Error.VariableValueTooLong;
        var free_index: ?usize = null;
        for (&self.entries, 0..) |*entry, index| {
            if (!entry.used) {
                if (free_index == null) free_index = index;
                continue;
            }
            if (!std.mem.eql(u8, entry.keySlice(), key)) continue;
            setEnvironmentEntry(entry, key, value);
            return;
        }
        const index = free_index orelse return Error.EnvironmentFull;
        setEnvironmentEntry(&self.entries[index], key, value);
    }

    pub fn unset(self: *Environment, key: []const u8) bool {
        for (&self.entries) |*entry| {
            if (!entry.used or !std.mem.eql(u8, entry.keySlice(), key)) continue;
            entry.* = .{};
            return true;
        }
        return false;
    }

    pub fn get(self: *const Environment, key: []const u8) ?[]const u8 {
        for (&self.entries) |*entry| if (entry.used and std.mem.eql(u8, entry.keySlice(), key)) return entry.valueSlice();
        return null;
    }

    pub fn count(self: *const Environment) usize {
        var total: usize = 0;
        for (self.entries) |entry| total += @intFromBool(entry.used);
        return total;
    }
};

pub fn parse(line: []const u8, environment: *const Environment) Error!CommandLine {
    if (line.len > maximum_line_length) return Error.TooLong;
    var result = CommandLine{};
    result.stage_count = 1;
    var stage_index: usize = 0;
    var index: usize = 0;
    var token_buffer: [maximum_token_length + 1]u8 = @splat(0);
    var token_length: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    var token_started = false;
    var expect_redirection: Redirection = .none;

    while (index <= line.len) : (index += 1) {
        const at_end = index == line.len;
        const character: u8 = if (at_end) 0 else line[index];

        if (escaped) {
            if (at_end) return Error.DanglingEscape;
            try appendByte(&token_buffer, &token_length, character);
            token_started = true;
            escaped = false;
            continue;
        }
        if (!at_end and character == '\\' and quote != '\'') {
            escaped = true;
            token_started = true;
            continue;
        }
        if (quote != 0) {
            if (at_end) return Error.UnterminatedQuote;
            if (character == quote) {
                quote = 0;
                token_started = true;
                continue;
            }
            if (character == '$' and quote == '"') {
                index = try expandVariable(line, index, environment, &token_buffer, &token_length);
                token_started = true;
                continue;
            }
            try appendByte(&token_buffer, &token_length, character);
            token_started = true;
            continue;
        }
        if (!at_end and (character == '\'' or character == '"')) {
            quote = character;
            token_started = true;
            continue;
        }
        if (!at_end and character == '$') {
            index = try expandVariable(line, index, environment, &token_buffer, &token_length);
            token_started = true;
            continue;
        }

        const operator = !at_end and (character == '|' or character == '<' or character == '>' or character == '&');
        const separator = at_end or character == ' ' or character == '\t' or operator or character == '#';
        if (!separator) {
            try appendByte(&token_buffer, &token_length, character);
            token_started = true;
            continue;
        }

        if (token_started) {
            try commitToken(&result, stage_index, token_buffer[0..token_length], &expect_redirection);
            token_buffer = @splat(0);
            token_length = 0;
            token_started = false;
        }
        if (at_end or character == '#') break;
        if (character == ' ' or character == '\t') continue;

        switch (character) {
            '|' => {
                if (expect_redirection != .none or result.stages[stage_index].count == 0) return Error.InvalidPipeline;
                if (stage_index + 1 >= result.stages.len) return Error.TooManyStages;
                stage_index += 1;
                result.stage_count = stage_index + 1;
            },
            '<' => {
                if (expect_redirection != .none or result.input_path != null) return Error.DuplicateRedirection;
                expect_redirection = .input;
            },
            '>' => {
                if (expect_redirection != .none or result.output_path != null) return Error.DuplicateRedirection;
                if (index + 1 < line.len and line[index + 1] == '>') {
                    expect_redirection = .append;
                    index += 1;
                } else {
                    expect_redirection = .output;
                }
            },
            '&' => {
                var trailing = index + 1;
                while (trailing < line.len and (line[trailing] == ' ' or line[trailing] == '\t')) trailing += 1;
                if (trailing < line.len and line[trailing] != '#') return Error.InvalidBackgroundPlacement;
                result.background = true;
                index = line.len;
            },
            else => unreachable,
        }
    }

    if (quote != 0) return Error.UnterminatedQuote;
    if (escaped) return Error.DanglingEscape;
    if (expect_redirection != .none) return Error.MissingRedirectionTarget;
    for (result.stages[0..result.stage_count]) |stage| if (stage.count == 0) return Error.InvalidPipeline;
    if (result.stages[0].count == 0) return Error.EmptyCommand;
    return result;
}

fn commitToken(result: *CommandLine, stage_index: usize, value: []const u8, expectation: *Redirection) Error!void {
    switch (expectation.*) {
        .input => {
            var token = Token{};
            try token.set(value);
            result.input_path = token;
            expectation.* = .none;
        },
        .output, .append => |kind| {
            var token = Token{};
            try token.set(value);
            result.output_path = token;
            result.append_output = kind == .append;
            expectation.* = .none;
        },
        .none => {
            var stage = &result.stages[stage_index];
            if (stage.count >= stage.arguments.len) return Error.TooManyArguments;
            try stage.arguments[stage.count].set(value);
            stage.count += 1;
        },
    }
}

fn expandVariable(
    line: []const u8,
    dollar_index: usize,
    environment: *const Environment,
    output: *[maximum_token_length + 1]u8,
    output_length: *usize,
) Error!usize {
    if (dollar_index + 1 >= line.len) {
        try appendByte(output, output_length, '$');
        return dollar_index;
    }
    var start = dollar_index + 1;
    var end = start;
    var braced = false;
    if (line[start] == '{') {
        braced = true;
        start += 1;
        end = start;
        while (end < line.len and line[end] != '}') end += 1;
        if (end >= line.len) return Error.InvalidVariableName;
    } else {
        while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) end += 1;
    }
    if (end == start) {
        try appendByte(output, output_length, '$');
        return dollar_index;
    }
    const key = line[start..end];
    if (!validVariableName(key)) return Error.InvalidVariableName;
    if (environment.get(key)) |value| for (value) |byte| try appendByte(output, output_length, byte);
    return if (braced) end else end - 1;
}

fn appendByte(output: *[maximum_token_length + 1]u8, length: *usize, value: u8) Error!void {
    if (length.* >= maximum_token_length) return Error.TooLong;
    output[length.*] = value;
    length.* += 1;
}

fn validVariableName(key: []const u8) bool {
    if (key.len == 0 or key.len > maximum_token_length) return false;
    if (!(std.ascii.isAlphabetic(key[0]) or key[0] == '_')) return false;
    for (key[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return true;
}

fn setEnvironmentEntry(entry: *EnvironmentEntry, key: []const u8, value: []const u8) void {
    entry.* = .{
        .used = true,
        .key_length = @intCast(key.len),
        .value_length = @intCast(value.len),
    };
    @memcpy(entry.key[0..key.len], key);
    @memcpy(entry.value[0..value.len], value);
}

pub const EditorEvent = union(enum) {
    none,
    redraw,
    submitted: []const u8,
    cancelled,
    end_of_input,
};

pub const LineEditor = struct {
    buffer: [maximum_line_length + 1]u8 = @splat(0),
    length: usize = 0,
    cursor: usize = 0,
    history: [maximum_history][maximum_line_length + 1]u8 = @splat(@splat(0)),
    history_lengths: [maximum_history]u16 = @splat(0),
    history_count: usize = 0,
    history_head: usize = 0,
    history_view: ?usize = null,
    escape_state: enum { none, escape, bracket, delete_tilde } = .none,

    pub fn line(self: *const LineEditor) []const u8 {
        return self.buffer[0..self.length];
    }

    pub fn reset(self: *LineEditor) void {
        @memset(&self.buffer, 0);
        self.length = 0;
        self.cursor = 0;
        self.history_view = null;
        self.escape_state = .none;
    }

    pub fn feed(self: *LineEditor, byte: u8) EditorEvent {
        if (self.escape_state != .none) return self.feedEscape(byte);
        switch (byte) {
            0x1B => {
                self.escape_state = .escape;
                return .none;
            },
            '\r', '\n' => {
                if (self.length == 0) return .{ .submitted = self.buffer[0..0] };
                self.pushHistory(self.line());
                return .{ .submitted = self.line() };
            },
            0x03 => {
                self.reset();
                return .cancelled;
            },
            0x04 => {
                if (self.length == 0) return .end_of_input;
                if (self.cursor < self.length) self.deleteAtCursor();
                return .redraw;
            },
            0x08, 0x7F => {
                if (self.cursor == 0) return .none;
                self.cursor -= 1;
                self.deleteAtCursor();
                return .redraw;
            },
            0x15 => {
                self.reset();
                return .redraw;
            },
            0x01 => {
                self.cursor = 0;
                return .redraw;
            },
            0x05 => {
                self.cursor = self.length;
                return .redraw;
            },
            0x20...0x7E => {
                if (self.length >= maximum_line_length) return .none;
                var index = self.length;
                while (index > self.cursor) : (index -= 1) self.buffer[index] = self.buffer[index - 1];
                self.buffer[self.cursor] = byte;
                self.cursor += 1;
                self.length += 1;
                return .redraw;
            },
            else => return .none,
        }
    }

    fn feedEscape(self: *LineEditor, byte: u8) EditorEvent {
        switch (self.escape_state) {
            .escape => {
                self.escape_state = if (byte == '[') .bracket else .none;
                return .none;
            },
            .bracket => {
                self.escape_state = .none;
                switch (byte) {
                    'A' => self.historyPrevious(),
                    'B' => self.historyNext(),
                    'C' => if (self.cursor < self.length) {
                        self.cursor += 1;
                    },
                    'D' => if (self.cursor > 0) {
                        self.cursor -= 1;
                    },
                    'H' => self.cursor = 0,
                    'F' => self.cursor = self.length,
                    '3' => {
                        self.escape_state = .delete_tilde;
                        return .none;
                    },
                    else => return .none,
                }
                return .redraw;
            },
            .delete_tilde => {
                self.escape_state = .none;
                if (byte == '~' and self.cursor < self.length) {
                    self.deleteAtCursor();
                    return .redraw;
                }
                return .none;
            },
            .none => unreachable,
        }
    }

    fn deleteAtCursor(self: *LineEditor) void {
        var index = self.cursor;
        while (index + 1 < self.length) : (index += 1) self.buffer[index] = self.buffer[index + 1];
        self.length -= 1;
        self.buffer[self.length] = 0;
    }

    fn pushHistory(self: *LineEditor, value: []const u8) void {
        if (value.len == 0) return;
        if (self.history_count > 0) {
            const latest_index = (self.history_head + maximum_history - 1) % maximum_history;
            if (self.history_lengths[latest_index] == value.len and std.mem.eql(u8, self.history[latest_index][0..value.len], value)) return;
        }
        @memset(&self.history[self.history_head], 0);
        @memcpy(self.history[self.history_head][0..value.len], value);
        self.history_lengths[self.history_head] = @intCast(value.len);
        self.history_head = (self.history_head + 1) % maximum_history;
        self.history_count = @min(self.history_count + 1, maximum_history);
        self.history_view = null;
    }

    fn historyPrevious(self: *LineEditor) void {
        if (self.history_count == 0) return;
        const current = self.history_view orelse self.history_count;
        if (current == 0) return;
        self.history_view = current - 1;
        self.loadHistory(current - 1);
    }

    fn historyNext(self: *LineEditor) void {
        const current = self.history_view orelse return;
        if (current + 1 >= self.history_count) {
            self.reset();
            return;
        }
        self.history_view = current + 1;
        self.loadHistory(current + 1);
    }

    fn loadHistory(self: *LineEditor, logical_index: usize) void {
        const oldest = (self.history_head + maximum_history - self.history_count) % maximum_history;
        const physical = (oldest + logical_index) % maximum_history;
        const length: usize = self.history_lengths[physical];
        @memset(&self.buffer, 0);
        @memcpy(self.buffer[0..length], self.history[physical][0..length]);
        self.length = length;
        self.cursor = length;
    }
};

test "parser handles quotes escapes variables and comments" {
    var env = Environment.init();
    try env.set("TARGET", "world");
    const command = try parse("echo \"hello $TARGET\" 'literal $TARGET' escaped\\ space # ignored", &env);
    try std.testing.expectEqual(@as(usize, 1), command.stage_count);
    try std.testing.expectEqual(@as(usize, 4), command.stages[0].count);
    try std.testing.expectEqualStrings("echo", command.stages[0].arguments[0].slice());
    try std.testing.expectEqualStrings("hello world", command.stages[0].arguments[1].slice());
    try std.testing.expectEqualStrings("literal $TARGET", command.stages[0].arguments[2].slice());
    try std.testing.expectEqualStrings("escaped space", command.stages[0].arguments[3].slice());
}

test "parser builds pipelines redirections and background jobs" {
    const env = Environment.init();
    const command = try parse("cat < input | grep key | sort >> output &", &env);
    try std.testing.expectEqual(@as(usize, 3), command.stage_count);
    try std.testing.expectEqualStrings("input", command.input_path.?.slice());
    try std.testing.expectEqualStrings("output", command.output_path.?.slice());
    try std.testing.expect(command.append_output);
    try std.testing.expect(command.background);
}

test "parser rejects malformed operators and quotes" {
    const env = Environment.init();
    try std.testing.expectError(Error.InvalidPipeline, parse("| echo", &env));
    try std.testing.expectError(Error.InvalidPipeline, parse("echo |", &env));
    try std.testing.expectError(Error.MissingRedirectionTarget, parse("echo >", &env));
    try std.testing.expectError(Error.UnterminatedQuote, parse("echo 'x", &env));
    try std.testing.expectError(Error.InvalidBackgroundPlacement, parse("echo & later", &env));
}

test "environment supports update unset and bounded validation" {
    var env = Environment.init();
    try env.set("A", "one");
    try env.set("A", "two");
    try std.testing.expectEqualStrings("two", env.get("A").?);
    try std.testing.expect(env.unset("A"));
    try std.testing.expect(env.get("A") == null);
    try std.testing.expectError(Error.InvalidVariableName, env.set("1BAD", "x"));
}

test "line editor supports insertion movement deletion and control keys" {
    var editor = LineEditor{};
    _ = editor.feed('a');
    _ = editor.feed('c');
    _ = editor.feed(0x1B);
    _ = editor.feed('[');
    _ = editor.feed('D');
    _ = editor.feed('b');
    try std.testing.expectEqualStrings("abc", editor.line());
    _ = editor.feed(0x01);
    _ = editor.feed(0x04);
    try std.testing.expectEqualStrings("bc", editor.line());
    _ = editor.feed(0x15);
    try std.testing.expectEqual(@as(usize, 0), editor.length);
}

test "line editor retains deduplicated history and ANSI navigation" {
    var editor = LineEditor{};
    for ("first") |byte| _ = editor.feed(byte);
    _ = editor.feed('\n');
    editor.reset();
    for ("second") |byte| _ = editor.feed(byte);
    _ = editor.feed('\n');
    editor.reset();
    _ = editor.feed(0x1B);
    _ = editor.feed('[');
    _ = editor.feed('A');
    try std.testing.expectEqualStrings("second", editor.line());
    _ = editor.feed(0x1B);
    _ = editor.feed('[');
    _ = editor.feed('A');
    try std.testing.expectEqualStrings("first", editor.line());
    _ = editor.feed(0x1B);
    _ = editor.feed('[');
    _ = editor.feed('B');
    try std.testing.expectEqualStrings("second", editor.line());
}
