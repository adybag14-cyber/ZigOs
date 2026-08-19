pub const Error = error{WriteZero};

pub fn copy(reader: anytype, writer: anytype, scratch: []u8) !void {
    if (scratch.len == 0) return;

    while (true) {
        const count = try reader.read(scratch);
        if (count == 0) return;

        var offset: usize = 0;
        while (offset < count) {
            const written = try writer.write(scratch[offset..count]);
            if (written == 0) return Error.WriteZero;
            offset += written;
        }
    }
}

test "copy handles repeated partial reads and writes" {
    const std = @import("std");
    const payload = "G291-partial-io-copy-payload-crosses-many-short-operations";

    const ShortReader = struct {
        bytes: []const u8,
        offset: usize = 0,
        calls: usize = 0,

        fn read(self: *@This(), output: []u8) !usize {
            self.calls += 1;
            if (self.offset == self.bytes.len) return 0;
            const count = @min(@min(output.len, 5), self.bytes.len - self.offset);
            @memcpy(output[0..count], self.bytes[self.offset .. self.offset + count]);
            self.offset += count;
            return count;
        }
    };

    const ShortWriter = struct {
        bytes: [128]u8 = undefined,
        length: usize = 0,
        calls: usize = 0,

        fn write(self: *@This(), input: []const u8) !usize {
            self.calls += 1;
            const count = @min(input.len, 3);
            @memcpy(self.bytes[self.length .. self.length + count], input[0..count]);
            self.length += count;
            return count;
        }
    };

    var reader = ShortReader{ .bytes = payload };
    var writer: ShortWriter = .{};
    var scratch: [11]u8 = undefined;
    try copy(&reader, &writer, &scratch);

    try std.testing.expectEqualSlices(u8, payload, writer.bytes[0..writer.length]);
    try std.testing.expect(reader.calls > 2);
    try std.testing.expect(writer.calls > reader.calls);
}

test "copy rejects a zero-progress partial write" {
    const std = @import("std");

    const Reader = struct {
        finished: bool = false,

        fn read(self: *@This(), output: []u8) !usize {
            if (self.finished) return 0;
            self.finished = true;
            output[0] = 'X';
            return 1;
        }
    };

    const ZeroWriter = struct {
        calls: usize = 0,

        fn write(self: *@This(), _: []const u8) !usize {
            self.calls += 1;
            return 0;
        }
    };

    var reader: Reader = .{};
    var writer: ZeroWriter = .{};
    var scratch: [4]u8 = undefined;
    try std.testing.expectError(Error.WriteZero, copy(&reader, &writer, &scratch));
    try std.testing.expectEqual(@as(usize, 1), writer.calls);
}
