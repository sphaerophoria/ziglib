const std = @import("std");
//
// * Underlying writer
// * Current byte that we haven't finished
//

//struct {
//    writer: Writer,
//    current_byte: u8,
//    byte_progress: u8,
//}
//pub fn BitWriter(comptime Writer: type) type {
//    return struct {
//        writer: Writer,
//        const Self = @This();
//
//        fn write(self: Self, bytes: []const u8) {
//
//        }
//    }
//}

pub fn BitWriter(comptime Writer: type) type {
    return struct {
        writer: Writer,
        current_byte: u8 = 0,
        byte_progress: u8 = 0,

        const Self = @This();

        pub fn init(writer: Writer) Self {
            return Self{ .writer = writer };
        }

        pub fn write(self: *Self, data: u8, num_bits: u8) !void {
            var first_chunk_size = @min(8 - self.byte_progress, num_bits);
            var first_chunk_mask: u8 = @intCast((@as(u16, 1) << @intCast(first_chunk_size)) - 1);

            self.current_byte |= (data & first_chunk_mask) << @intCast(self.byte_progress);
            self.byte_progress += first_chunk_size;

            if (self.byte_progress == 8) {
                _ = try self.writer.writeByte(self.current_byte);
                self.byte_progress = 0;
                self.current_byte = 0;
            }

            if (first_chunk_size == 8) {
                return;
            }

            var second_chunk_size: u8 = @intCast(num_bits - first_chunk_size);
            // FIXME: Factor out a function
            var second_chunk_mask: u8 = @intCast((@as(u16, 1) << @intCast(second_chunk_size)) - 1);

            self.current_byte |= (data >> @intCast(first_chunk_size)) & second_chunk_mask;
            self.byte_progress += second_chunk_size;
        }

        pub fn finish(self: *Self) !void {
            // FIXME: This should invalidate the writer somehow?
            if (self.byte_progress > 0) {
                try self.writer.writeByte(self.current_byte);
            }
        }
    };
}

pub fn bitWriter(writer: anytype) BitWriter(@TypeOf(writer)) {
    return BitWriter(@TypeOf(writer)).init(writer);
}

const expect = std.testing.expect;

test "full byte" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    var bw = bitWriter(buf.writer());
    try bw.write('a', 8);
    try bw.finish();

    try expect(std.mem.eql(u8, buf.items, "a"));
}

test "2 byte segments" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    var bw = bitWriter(buf.writer());
    try bw.write('a', 6);
    try bw.write('a' >> 6, 2);
    try bw.finish();

    try std.testing.expectEqualSlices(u8, "a", buf.items);
}

test "unfinished byte" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    var bw = bitWriter(buf.writer());
    try bw.write(1, 1);
    try expect(std.mem.eql(u8, buf.items, &.{}));

    try bw.finish();

    // Expect the single bit to only have been written after finishing
    try expect(std.mem.eql(u8, buf.items, &.{1}));
}

test "multiple bytes" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    var bw = bitWriter(buf.writer());
    try bw.write(0b0000_1111, 6);
    try bw.write(0b111, 3);
    try bw.write(0b101, 3);
    try bw.write(0b1010_0101, 8);

    try bw.finish();

    try std.testing.expectEqualSlices(u8, &.{ 0b1100_1111, 0b0101_1011, 0b1010 }, buf.items);
}
