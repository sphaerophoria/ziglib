const huffman = @import("huffman.zig");

pub fn HuffmanReader(comptime Reader: type) type {
    return struct {
        reader: Reader,
        current_byte: u8,
        // How many bits of the byte have we processed
        byte_progress: u8,
        table: *const huffman.HuffmanTable,
        bytes_read: usize,
        max_len: usize,

        const Self = @This();

        fn nextBit(self: *Self) !u1 {
            if (self.byte_progress >= 8) {
                self.current_byte = try self.reader.readByte();
                self.byte_progress = 0;
            }

            var ret: u1 = @truncate(self.current_byte >> @intCast(self.byte_progress));

            self.byte_progress += 1;
            return ret;
        }

        pub fn next(self: *Self) !?u8 {
            var node_idx = self.table.rootNodeIdx();

            if (self.bytes_read >= self.max_len) {
                return null;
            }

            while (true) {
                var branch = switch (self.table.nodes.items[node_idx]) {
                    .Leaf => |val| {
                        self.bytes_read += 1;
                        return val;
                    },
                    .Branch => |b| b,
                };

                const next_bit = try self.nextBit();
                node_idx = switch (next_bit) {
                    0 => branch.left,
                    1 => branch.right,
                };
            }
        }
    };
}

pub fn huffmanReader(reader: anytype, table: *const huffman.HuffmanTable, max_len: usize) HuffmanReader(@TypeOf(reader)) {
    return .{
        .reader = reader,
        .current_byte = 0,
        .byte_progress = 8,
        .table = table,
        .bytes_read = 0,
        .max_len = max_len,
    };
}
